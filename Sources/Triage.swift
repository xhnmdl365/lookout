// Triage: Claude's verdict on each open task, and its run log.
import SwiftUI
import AppKit

func appendRun(_ r: JudgeRun) {
    guard let line = try? JSONEncoder().encode(r) else { return }
    if let h = try? FileHandle(forWritingTo: judgeHistoryURL) {
        h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try? h.close()
    } else {
        try? (line + Data("\n".utf8)).write(to: judgeHistoryURL)
    }
}

// The last judge run, step by step, as Markdown: what Claude said, each tool call and
// the start of its result, then the verdicts.
func renderTrace(_ lines: [[String: Any]], titles: [String: String], started: Double, result: JudgeFile) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return one.count > n ? String(one.prefix(n)) + " …" : one
    }
    var md = ["# Claude triage run", "",
              "Started \(f.string(from: Date(timeIntervalSince1970: started))), one conversation over \(titles.count) tasks.", ""]
    // Results arrive after a batch of parallel calls; pair each with its call instead.
    var results: [String: String] = [:]
    for l in lines where l["type"] as? String == "user" {
        for c in (l["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        where c["type"] as? String == "tool_result" {
            let text = c["content"] as? String
                ?? (c["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
            results[c["tool_use_id"] as? String ?? ""] = ((c["is_error"] as? Bool) == true ? "❌ " : "") + clip(text, 300)
        }
    }
    var step = 0
    for l in lines {
        let content = (l["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch l["type"] as? String {
        case "assistant":
            for c in content {
                if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty {
                    md += ["💬 " + clip(t, 400), ""]
                } else if c["type"] as? String == "tool_use" {
                    step += 1
                    let input = c["input"] as? [String: Any] ?? [:]
                    let what = (input["command"] ?? input["file_path"] ?? input["pattern"]) as? String
                        ?? (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    md += ["**\(step). \(c["name"] as? String ?? "?")**", "```", clip(what, 600), "```"]
                    if let r = results[c["id"] as? String ?? ""] { md += ["> " + r, ""] }
                }
            }
        case "result":
            md += ["---", String(format: "%d turns, %.0f s, $%.2f at API prices",
                                 l["num_turns"] as? Int ?? 0, (l["duration_ms"] as? Double ?? 0) / 1000,
                                 l["total_cost_usd"] as? Double ?? 0), ""]
        default:
            break
        }
    }
    md += ["## Verdicts", ""]
    if let e = result.error { md.append("Error: " + e) }
    let label = ["done": "✅ Done (hard evidence)", "suggest_done": "💡 Suggested wrap-up", "active": "⏳ In progress"]
    for v in result.verdicts.sorted(by: { $0.verdict < $1.verdict }) {
        md.append("- \(label[v.verdict] ?? v.verdict) **\(titles[v.id] ?? v.id)**: \(v.reason)")
    }
    return md.joined(separator: "\n")
}

extension Store {
    // MARK: Claude judge (layers 2 and 3)

    // A task goes back to Claude only when its verdict is missing, stale (the session moved
    // since), or a day old: the last catches changes outside the session, like a PR merged by someone else.
    private func needsTriage(_ s: Session) -> Bool {
        guard let j = judge, let v = j.verdicts.first(where: { $0.id == s.id }) else { return true }
        let age = Date().timeIntervalSince1970 - (v.at ?? j.generatedAt)
        return !v.current(for: s, runAt: j.generatedAt) || age > reverifyHours * 3600
    }

    // `dry` only writes the task list Claude would get, to open-tasks.json, for checking.
    func runJudge(all: Bool = false, dry: Bool = false) {
        guard !judging else { return }
        let listed = judged
        let tasks = all ? listed : listed.filter(needsTriage)
        guard !tasks.isEmpty else {
            triageNote = "Nothing changed since the last triage"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.triageNote = nil }
            return
        }
        // Verdicts for listed tasks not sent this time carry over, each keeping its own time.
        let sent = Set(tasks.map(\.id)), listedIds = Set(listed.map(\.id))
        let carried: [Verdict] = (judge?.verdicts ?? []).filter { listedIds.contains($0.id) && !sent.contains($0.id) }
            .map { v in var v = v; v.at = v.at ?? self.judge?.generatedAt; return v }
        guard let claude = Tools.claude else {
            finishJudge(JudgeFile(generatedAt: Date().timeIntervalSince1970, verdicts: [],
                                  error: "Claude CLI not found: install Claude Code, or set claudePath in config.json"))
            return
        }
        judging = true
        // PR and ticket states are checked here first and handed over, so Claude needs no tools
        // and answers in one turn.
        refreshPRs {
            if dry {
                let iso = ISO8601DateFormatter()
                let data = try? JSONSerialization.data(withJSONObject: tasks.map { self.triageRow($0, iso: iso) },
                                                       options: [.prettyPrinted, .sortedKeys])
                try? data?.write(to: openTasksURL)
                self.judging = false
            } else {
                self.startJudge(claude, tasks: tasks, carried: carried)
            }
        }
    }

    // A task as Claude sees it: its status summary, plus PR and ticket states the app just checked.
    private func triageRow(_ s: Session, iso: ISO8601DateFormatter) -> [String: Any] {
        let recorded = Dictionary(s.prs.map { ($0.url, $0.state) }, uniquingKeysWith: { a, _ in a })
        let prs: [[String: Any]] = (textRefs[s.id] ?? s.prs.map(\.url)).sorted().map { url in
            let live = prLive[url]
            var pr: [String: Any] = [
                "pr": url.replacingOccurrences(of: "https://github.com/", with: ""),
                "state": live?.state ?? recorded[url] ?? "UNKNOWN",
                "checked": live != nil && live?.state != "UNKNOWN",
            ]
            if let e = live?.endedAt { pr["endedAt"] = iso.string(from: Date(timeIntervalSince1970: e)) }
            if let a = live?.author, let me { pr["author"] = a == me ? "the user" : "a teammate" }
            return pr
        }
        var ticketLine = ""
        if let k = ticket(for: s) {
            ticketLine = tickets[k].map { "\(k): \($0.status)" + ($0.done ? " (Done category)" : "") } ?? "\(k): status unknown"
        }
        return [
            "id": s.id, "title": s.title, "project": s.project,
            "source": s.isTerminal ? "terminal (no status summary; detail is the user's last prompt)" : "desktop",
            "kind": teamReviews.contains(s.id) ? "team code review" : "own work",
            "ticket": ticketLine,
            "status": s.pendingAsk != nil ? "blocked" : s.status ?? "", "detail": s.detail ?? "", "needs": s.nextStep ?? "",
            "lastActivity": iso.string(from: s.lastActivity),
            "prs": prs,
        ]
    }

    private func startJudge(_ claude: String, tasks: [Session], carried: [Verdict]) {
        let iso = ISO8601DateFormatter()
        let rows = tasks.map { triageRow($0, iso: iso) }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let list = String(data: data, encoding: .utf8),
              let promptURL = Bundle.main.url(forResource: "judge-prompt", withExtension: "md"),
              let template = try? String(contentsOf: promptURL, encoding: .utf8) else {
            finishJudge(JudgeFile(generatedAt: Date().timeIntervalSince1970, verdicts: [],
                                  error: "Couldn't build the task list or find judge-prompt.md"))
            return
        }
        try? data.write(to: openTasksURL)  // a copy of what was sent, for checking
        let prompt = template.replacingOccurrences(of: "{{TASKS}}", with: list)
        let schema = #"{"type":"object","properties":{"verdicts":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"verdict":{"enum":["done","suggest_done","active"]},"reason":{"type":"string"},"endedAt":{"type":"string"}},"required":["id","verdict","reason","endedAt"]}}},"required":["verdicts"]}"#
        let started = Date().timeIntervalSince1970
        let titles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .utility).async {
            // Every step streams to the trace; its last "result" line is what the run returned.
            FileManager.default.createFile(atPath: judgeTraceURL.path, contents: nil)
            let out = try? FileHandle(forWritingTo: judgeTraceURL)
            _ = run(claude, [
                "-p", "--model", triageModel, "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                "--strict-mcp-config", "--max-budget-usd", "2", "--json-schema", schema,
                // No tools: everything it needs is in the prompt, so it can't read anything else.
                "--tools", "",
            ], stdin: prompt, stdout: out)
            try? out?.close()
            var result = JudgeFile(generatedAt: started, verdicts: [], error: "Claude returned no result")
            let lines = ((try? String(contentsOf: judgeTraceURL, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            let obj = lines.last { $0["type"] as? String == "result" }
            if let obj, let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: judgeRawURL) }
            let usage = JudgeRun(at: started, raw: obj)
            appendRun(usage)
            DispatchQueue.main.async { self.runs.append(usage) }
            if let obj {
                if let so = obj["structured_output"],
                   let soData = try? JSONSerialization.data(withJSONObject: so),
                   let parsed = try? JSONDecoder().decode([String: [Verdict]].self, from: soData),
                   let v = parsed["verdicts"] {
                    let fresh = v.map { v in var v = v; v.at = started; return v }
                    result = JudgeFile(generatedAt: started, verdicts: carried + fresh, error: nil)
                } else if let msg = obj["result"] as? String {
                    result.error = msg.contains("authenticate")
                        ? "The Claude CLI is signed out: run `claude auth login` in a terminal"
                        : String(msg.prefix(200))
                }
            }
            try? renderTrace(lines, titles: titles, started: started, result: result)
                .write(to: judgeTraceMDURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { self.finishJudge(result) }
        }
    }

    private func finishJudge(_ result: JudgeFile) {
        // A failed run keeps the previous verdicts.
        if result.error == nil || judge == nil { judge = result } else { judge?.error = result.error }
        if let data = try? JSONEncoder().encode(judge) { try? data.write(to: judgeURL) }
        judging = false
        reload()
    }
}
