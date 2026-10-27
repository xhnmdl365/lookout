// Claude Tasks
// A floating, always-on-top panel listing Claude Code sessions as tasks: desktop app sessions,
// read-only from the app's own session files, and terminal `claude` sessions, read from their
// transcripts. Click a row to jump to the session.
import SwiftUI
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
let sessionsRoot = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
let projectsRoot = home.appendingPathComponent(".claude/projects")  // CLI transcripts, terminal sessions among them
let appSupport = home.appendingPathComponent("Library/Application Support")
let dataDir = appSupport.appendingPathComponent("ClaudeTasks")
let legacyDataDir = appSupport.appendingPathComponent("TaskFloat")  // the prototype's folder, moved over once
let configURL = dataDir.appendingPathComponent("config.json")
let stateURL = dataDir.appendingPathComponent("state.json")
let openTasksURL = dataDir.appendingPathComponent("open-tasks.json")
let judgeURL = dataDir.appendingPathComponent("judge.json")
let judgeRawURL = dataDir.appendingPathComponent("judge-raw.json")
let judgeHistoryURL = dataDir.appendingPathComponent("judge-history.jsonl")
let judgeTraceURL = dataDir.appendingPathComponent("judge-trace.jsonl")
let judgeTraceMDURL = dataDir.appendingPathComponent("judge-trace.md")
let daysDir = dataDir.appendingPathComponent("days")
let autoSummaryDays = 3  // past days without a summary get one automatically, this far back
let english = Locale(identifier: "en_US")

// MARK: - Local config and tools

// The user's own settings, in config.json in the data folder: outside the repo, so a personal
// setup never ends up shared. Every key is optional; a missing one falls back to a default or
// to what's found on the machine.
struct Config: Codable {
    var claudePath: String?
    var ghPath: String?
    var acliPath: String?
    var githubOrg: String?     // the org for "repo#123" mentions when no folder says which
    var triageModel: String?   // the model Triage and day summaries run on
    var activeHours: Double?
    var blockedDays: Double?
    var scheduledDays: Double?
    var prGraceHours: Double?
    var reverifyHours: Double?
    var refreshMinutes: Double?
}

// One outside tool's state: set up, needing a sign-in, or not installed. Claude Code powers
// Triage and day summaries; GitHub CLI checks PRs; Atlassian CLI (optional) reads Jira tickets.
struct Integration: Identifiable {
    enum State { case ready, signedOut, missing }
    let id: String
    let name: String
    let purpose: String
    let state: State
    let detail: String
    let fix: String?  // the command or step that sets it up

    static func check() -> [Integration] {
        var out: [Integration] = []

        if let claude = Tools.claude {
            let status = (try? JSONSerialization.jsonObject(with: Data(shell(claude, ["auth", "status"]).utf8))) as? [String: Any]
            let signedIn = (status?["loggedIn"] as? Bool) == true
            out.append(Integration(id: "claude", name: "Claude Code", purpose: "Triage and day summaries",
                                   state: signedIn ? .ready : .signedOut,
                                   detail: signedIn ? "Signed in" + ((status?["email"] as? String).map { " as \($0)" } ?? "") : "Signed out",
                                   fix: signedIn ? nil : "claude auth login"))
        } else {
            out.append(Integration(id: "claude", name: "Claude Code", purpose: "Triage and day summaries", state: .missing,
                                   detail: "Not found", fix: "Install Claude Code, or set claudePath in config.json"))
        }

        if let gh = Tools.gh {
            let login = shell(gh, ["api", "user", "-q", ".login"]).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Integration(id: "github", name: "GitHub CLI", purpose: "PR status: merged PRs close tasks",
                                   state: login.isEmpty ? .signedOut : .ready,
                                   detail: login.isEmpty ? "Signed out" : "Signed in as \(login)",
                                   fix: login.isEmpty ? "gh auth login" : nil))
        } else {
            out.append(Integration(id: "github", name: "GitHub CLI", purpose: "PR status: merged PRs close tasks", state: .missing,
                                   detail: "Not found", fix: "brew install gh"))
        }

        if let acli = Tools.acli {
            let status = shell(acli, ["jira", "auth", "status"])
            let site = captures(#"Site:\s*(\S+)"#, in: status).first?[1]
            let ok = status.contains("Authenticated")
            out.append(Integration(id: "jira", name: "Atlassian CLI", purpose: "Optional: Jira ticket status closes own work",
                                   state: ok ? .ready : .signedOut,
                                   detail: ok ? "Connected" + (site.map { " to \($0)" } ?? "") : "Signed out",
                                   fix: ok ? nil : "acli jira auth login --web"))
        } else {
            out.append(Integration(id: "jira", name: "Atlassian CLI", purpose: "Optional: Jira ticket status closes own work",
                                   state: .missing, detail: "Not installed", fix: "See the README to install acli"))
        }
        return out
    }
}

// An optional convention the user can add to their own ~/.claude/CLAUDE.md: Claude names a
// session reviewing a teammate's PR "Team code review: …", so the panel knows it for certain.
// Kept between markers, so it can be found and removed again.
enum NamingRule {
    static let url = home.appendingPathComponent(".claude/CLAUDE.md")
    static let start = "<!-- claude-tasks: session naming -->"
    static let end = "<!-- /claude-tasks: session naming -->"
    static let text = """
    # Session naming

    When a session's work is reviewing a pull request (a code review, PR review, or review
    comments), check who wrote the PR (`gh pr view <PR> --json author -q .author.login`) and who
    I am (`gh api user -q .login`).

    - If the PR is someone else's, name the session "Team code review: <ticket or PR> <short
      description>". In the Claude desktop app, set it with the session-title tool. In a terminal
      session, tell me the title so I can set it with /rename.
    - If the PR is mine (a self-review), don't add the prefix.
    """

    static var installed: Bool { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(start) }

    static func install() {
        var current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !current.contains(start) else { return }
        if !current.isEmpty && !current.hasSuffix("\n") { current += "\n" }
        current += (current.isEmpty ? "" : "\n") + "\(start)\n\(text)\n\(end)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? current.write(to: url, atomically: true, encoding: .utf8)
    }

    static func remove() {
        guard let current = try? String(contentsOf: url, encoding: .utf8),
              let a = current.range(of: start), let b = current.range(of: end, range: a.upperBound..<current.endIndex)
        else { return }
        var kept = current
        kept.removeSubrange(a.lowerBound..<b.upperBound)
        kept = kept.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        try? kept.trimmingCharacters(in: .whitespacesAndNewlines).appending(kept.isEmpty ? "" : "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}

// The prototype kept its data under another name; the first launch moves it across.
func migrateLegacyData() {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: dataDir.path), fm.fileExists(atPath: legacyDataDir.path) else { return }
    try? fm.moveItem(at: legacyDataDir, to: dataDir)
}

let config: Config = {
    migrateLegacyData()
    return (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
}()

// Where command-line tools usually live. An app started from Finder doesn't get the shell's
// PATH, so these are searched directly; config.json can name any other location.
let toolDirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home.path)/.local/bin", "\(home.path)/bin",
                "\(home.path)/.npm-global/bin", "\(home.path)/.bun/bin", "/usr/bin", "/bin"]
let toolPATH = toolDirs.joined(separator: ":")

func findTool(_ name: String, configured: String?) -> String? {
    ([configured].compactMap { $0 } + toolDirs.map { "\($0)/\(name)" })
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

// Looked up each time, so a tool installed while the app runs is picked up.
enum Tools {
    static var claude: String? { findTool("claude", configured: config.claudePath) }
    static var gh: String? { findTool("gh", configured: config.ghPath) }
    static var acli: String? { findTool("acli", configured: config.acliPath) }
}

let triageModel = config.triageModel ?? "sonnet"

// Classification rule (spike):
//   archived / scheduled-run noise -> ignored, except tracked sessions (see "done" below)
//   scheduled-task runs            -> only the latest run per task, in its own section
//   done (manual or auto)          -> "Done today" on the day it was marked, then gone
//   blocked, <= 14 days            -> "Needs you"
//   activity within 36h, or pinned -> "In progress"
//   anything else still open       -> "Idle lately", however old (finished or parked?)
//   on hold (manual)               -> "On hold": no age limit, skipped by Claude, back to normal on new activity
// Auto-done, hard evidence only:
//   layer 1 (here):   tracked session archived / deleted; all its PRs merged or closed (gh refreshed)
//                     and no work in the session after the last merge (beyond prGraceHours)
//   layer 2 (Claude): a PR named in the task's status (e.g. the PR under review) merged or closed
// Layer 3 (Claude, no hard evidence): a suggestion the user accepts or ignores.
// Each day's view is kept as a snapshot (days/<date>.json), rewritten only while that day lasts;
// afterwards only the user's own edits change it.
let activeHours = config.activeHours ?? 36
let scheduledDays = config.scheduledDays ?? 7    // a scheduled task's latest run shows this long
let blockedDays = config.blockedDays ?? 14       // blocked longer than this counts as idle, not "Needs you"
let prRefreshMinutes = config.refreshMinutes ?? 10  // how often PRs and tickets are checked
let prGraceHours = config.prGraceHours ?? 6      // activity this long after the last merge still counts as wrap-up
let reverifyHours = config.reverifyHours ?? 24   // an unchanged task's verdict is checked again after this long

// Mark reasons the rules match on.
let reasonManual = "Manual"
let reasonArchived = "Archived"
let reasonDeleted = "Deleted"

struct PR: Hashable {
    let url: String
    let number: Int
    let state: String
}

struct Session: Identifiable, Equatable {
    let id: String
    let cliId: String?
    let title: String
    let cwd: String     // the repo the session belongs to (a worktree's origin)
    let runCwd: String  // where it actually ran
    let lastActivity: Date
    let status: String?
    let detail: String?
    let needs: String?
    let scheduledTaskId: String?
    let prs: [PR]
    let archived: Bool
    let deleted: Bool
    var branch: String? = nil  // terminal sessions: the git branch they were on
    var parentId: String? = nil  // desktop sessions started from another session (shown nested under it)
    var startedAt: Date? = nil
    var pendingAsk: String? = nil  // a question the session's last turn left for the user, still unanswered

    // Waiting on the user: the app's own summary says blocked, or the last turn asked something.
    var waiting: Bool { status == "blocked" || pendingAsk != nil }
    var nextStep: String? { needs.flatMap { $0.isEmpty ? nil : $0 } ?? pendingAsk }

    var age: TimeInterval { Date().timeIntervalSince(lastActivity) }

    // A `claude` run in a terminal rather than the desktop app; its id is "cli_<session uuid>".
    var isTerminal: Bool { id.hasPrefix("cli_") }

    var project: String { projectName(cwd) }
}

func projectName(_ cwd: String) -> String {
    cwd.contains("/scratch-workspaces/") ? "No folder" : (cwd as NSString).lastPathComponent
}

struct Mark: Codable {
    var at: Double
    var reason: String
    var auto: Bool
}

struct Known: Codable, Equatable {
    var title: String
    var cwd: String
}

// The only state we own.
struct Manual: Codable {
    var doneAt: [String: Double] = [:]  // v1 manual marks, migrated into `marks`
    var marks: [String: Mark]? = [:]
    var pinned: Set<String>? = []
    var dismissed: Set<String>? = []    // auto marks undone ("<id>") and suggestions ignored ("s:<id>")
    var known: [String: Known]? = [:]   // sessions seen open, so archive/delete can close them
    var onHold: [String: Double]? = [:] // id -> when the user put it on hold
}

struct Verdict: Codable {
    let id: String
    let verdict: String  // done | suggest_done | active
    let reason: String
    let endedAt: String?  // done: when the evidence PRs were last merged or closed
    var at: Double?       // when Claude gave it; verdicts carried over from earlier runs keep theirs

    // A verdict speaks for the session as it was then; work since makes it stale.
    func current(for s: Session, runAt: Double) -> Bool { s.lastActivity.timeIntervalSince1970 <= (at ?? runAt) }

    // A done verdict only counts if the session stopped when the PRs landed.
    func holds(lastActivity: Date) -> Bool {
        guard verdict == "done", let e = endedAt.flatMap(ISO8601DateFormatter().date) else { return false }
        return lastActivity.timeIntervalSince(e) <= prGraceHours * 3600
    }
}

struct JudgeFile: Codable {
    var generatedAt: Double
    var verdicts: [Verdict]
    var error: String?
}

// One background Claude run, as the CLI reported it. costUSD is the CLI's API-price
// equivalent; on a claude.ai subscription login the run counts against plan limits instead.
struct JudgeRun: Codable {
    var at: Double
    var durationMs: Double
    var costUSD: Double
    var tokensIn: Int   // input + cache writes + cache reads
    var tokensOut: Int
    var turns: Int
    var ok: Bool
    var kind: String?  // nil: judge; "summary": day summary

    init(at: Double, raw: [String: Any]?) {
        let u = raw?["usage"] as? [String: Any] ?? [:]
        func n(_ k: String) -> Int { u[k] as? Int ?? 0 }
        self.at = at
        durationMs = raw?["duration_ms"] as? Double ?? 0
        costUSD = raw?["total_cost_usd"] as? Double ?? 0
        tokensIn = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
        tokensOut = n("output_tokens")
        turns = raw?["num_turns"] as? Int ?? 0
        ok = (raw?["is_error"] as? Bool) == false
    }
}

// A task as it stood on one day.
struct SnapTask: Codable, Identifiable {
    var id: String
    var title: String
    var project: String
    var section: String  // needsYou | active | idle | onHold | done
    var detail: String?
    var needs: String?
    var doneReason: String?
    var lastActivity: Double
    var deleted: Bool
}

struct DaySnapshot: Codable {
    var day: String  // yyyy-MM-dd
    var updatedAt: Double
    var tasks: [SnapTask]
    var summary: String?
    var summaryAt: Double?
    var summaryEdited: Bool?
    var userDone: [String: Bool]?  // the user's later corrections to this day

    func isDone(_ t: SnapTask) -> Bool { userDone?[t.id] ?? (t.section == "done") }
}

func dayKey(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

func dayDate(_ key: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: key) ?? Date()
}

func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = english
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

// Where the CLI keeps a session's transcript: its folder, with every character that isn't a
// letter or digit turned into "-", under ~/.claude/projects.
func transcriptURL(cwd: String, cliId: String) -> URL {
    let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    return projectsRoot.appendingPathComponent(folder).appendingPathComponent("\(cliId).jsonl")
}

// The question a session's last turn left open: its closing wrap-up asked something (or said it
// is blocked on the user), and no message from the user has come since. Read from the end of the
// transcript only.
func pendingQuestion(in url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
    let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    var pending: String?
    for line in tail.split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        let content = (o["message"] as? [String: Any])?["content"]
        if o["type"] as? String == "assistant" {
            for c in content as? [[String: Any]] ?? [] where (c["name"] as? String)?.hasSuffix("__wrap_up") == true {
                let input = c["input"] as? [String: Any] ?? [:]
                let ask = (input["ask"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                pending = ask ?? ((input["blocked"] as? Bool) == true ? input["recap"] as? String : nil)
            }
        } else if o["type"] as? String == "user", (o["isMeta"] as? Bool) != true {
            // A reply typed by the user answers it; tool results and system notices don't.
            let typed = (content as? String).map { !$0.hasPrefix("<") }
                ?? (content as? [[String: Any]])?.contains { $0["type"] as? String == "text" } ?? false
            if typed { pending = nil }
        }
    }
    return pending
}

// Who wrote a transcript, from its first lines: "cli" is an interactive terminal run,
// "claude-desktop" the desktop app. Desktop transcripts share the folder and are skipped.
func transcriptEntrypoint(_ url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let head = String(decoding: h.readData(ofLength: 65536), as: UTF8.self)
    for line in head.split(separator: "\n") {
        if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
           let e = o["entrypoint"] as? String { return e }
    }
    return nil
}

// A terminal session read from its whole transcript.
func parseTerminalSession(_ url: URL, mtime: Double, created: Date?) -> Session? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var title: String?, first: String?, firstCommand: String?, lastPrompt: String?, cwd: String?, branch: String?
    func tag(_ name: String, _ s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>"), a.upperBound <= b.lowerBound else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    for line in text.split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if cwd == nil { cwd = o["cwd"] as? String }
        if let b = o["gitBranch"] as? String, !b.isEmpty { branch = b }
        switch o["type"] as? String {
        case "custom-title": title = o["customTitle"] as? String ?? title
        case "last-prompt": lastPrompt = o["lastPrompt"] as? String ?? lastPrompt
        case "user":
            // The first thing the user typed; skip command wrappers and tool results.
            guard (o["isMeta"] as? Bool) != true,
                  let c = (o["message"] as? [String: Any])?["content"] as? String else { break }
            if first == nil, !c.hasPrefix("<") { first = c }
            if firstCommand == nil, let name = tag("command-name", c) {
                firstCommand = [name, tag("command-args", c) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            }
        default: break
        }
    }
    guard let cwd else { return nil }
    let clip = { (s: String) in s.count > 60 ? String(s.prefix(60)) + "…" : s }
    let uuid = url.deletingPathExtension().lastPathComponent
    return Session(
        id: "cli_" + uuid, cliId: uuid,
        title: title ?? (first ?? firstCommand).map(clip) ?? "(terminal session)",
        cwd: cwd, runCwd: cwd, lastActivity: Date(timeIntervalSince1970: mtime),
        status: nil,
        detail: (lastPrompt ?? first).map { "Last prompt: " + clip($0) },
        needs: nil, scheduledTaskId: nil, prs: [], archived: false, deleted: false,
        branch: branch, startedAt: created)
}

// How long a session has run, start to last activity: "45m", "3h 20m", "2d 4h".
func span(_ seconds: TimeInterval) -> String {
    let minutes = max(Int(seconds / 60), 1)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
    return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
}

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// The tty of a terminal `claude` process running this session, if any. A process started
// with `--resume <id>` names it; a fresh one is matched by working directory, if this is
// the newest terminal session there.
func runningTTY(for s: Session, newestInCwd: Bool) -> String? {
    guard let uuid = s.cliId else { return nil }
    for line in shell("/bin/ps", ["-axo", "pid=,tty=,args="]).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[1] != "??",
              let exe = parts[2].split(separator: " ").first, (exe as NSString).lastPathComponent == "claude"
        else { continue }
        let tty = "/dev/" + parts[1]
        if parts[2].contains(uuid) { return tty }
        guard newestInCwd, !parts[2].contains("--resume"), !parts[2].contains(" -r ") else { continue }
        let cwd = shell("/usr/sbin/lsof", ["-a", "-p", String(parts[0]), "-d", "cwd", "-Fn"])
            .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        if cwd == s.runCwd { return tty }
    }
    return nil
}

// Each match's capture groups (index 0 is the whole match).
func captures(_ pattern: String, in s: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

// The GitHub "owner/repo" a folder's origin remote points to; nil for other hosts, or for a
// wrapper repo holding several GitHub repos, where a bare PR number would be ambiguous.
func githubRepo(of folder: String) -> String? {
    let remote = shell("/usr/bin/git", ["-C", folder, "remote", "get-url", "origin"])
    guard let m = captures(#"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?\s*$"#, in: remote).first else { return nil }
    return "\(m[1])/\(m[2])"
}

// PRs named in a task's text, as URLs: full GitHub links; "repo#123", taken to share the
// owner of the folder's repo (or, failing that, the owner most of the user's folders use);
// and bare "#123" in the folder's own repo. Bare numbers need two digits, so "Minor #2" in a
// review isn't one.
func prRefs(in text: String, repo: String?, defaultOwner: String?) -> [String] {
    var urls: [String] = []
    for m in captures(#"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)"#, in: text) {
        urls.append("https://github.com/\(m[1])/\(m[2])/pull/\(m[3])")
    }
    if let owner = repo.flatMap({ $0.split(separator: "/").first.map(String.init) }) ?? defaultOwner {
        for m in captures(#"(?<![\w/.-])([A-Za-z][\w.-]*[A-Za-z0-9])#(\d+)\b"#, in: text) where m[1] != "PR" && m[1] != "PRs" {
            urls.append("https://github.com/\(owner)/\(m[1])/pull/\(m[2])")
        }
    }
    if let repo {
        for m in captures(#"(?<![\w/#])#(\d{2,})\b"#, in: text) {
            urls.append("https://github.com/\(repo)/pull/\(m[1])")
        }
    }
    var seen = Set<String>()
    return urls.filter { seen.insert($0).inserted }
}

// The GitHub owner most of the user's folders point to: their team's org, usually. Used for
// "repo#123" mentions in folders that aren't a GitHub repo themselves.
func commonOwner(_ repos: [String: String?]) -> String? {
    let owners = repos.values.compactMap { $0?.split(separator: "/").first.map(String.init) }
    return Dictionary(grouping: owners, by: { $0 }).max { $0.value.count < $1.value.count }?.key
}

// The session-naming convention for reviewing a teammate's PR: the title starts "Team code review".
func namedTeamReview(_ title: String) -> Bool {
    title.range(of: #"^team\s+code\s+review\b"#, options: [.regularExpression, .caseInsensitive]) != nil
}

// The Jira key a task is about, from its title: "PROJ-123 …", "ABC2-45: …". Keys mentioned
// only in the status (another team's ticket, say) aren't the task's own.
func ticketKey(_ title: String) -> String? { captures(#"\b([A-Z][A-Z0-9]+-\d+)\b"#, in: title).first?[1] }

// A work item's status from `acli jira workitem view --json`: its name, whether Jira files it
// under Done, and when it last changed category. Found by key name, wherever acli nests it.
func parseTicket(_ out: String) -> (status: String, done: Bool, changedAt: Double?)? {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) else { return nil }
    func find(_ key: String, in o: Any) -> Any? {
        if let d = o as? [String: Any] {
            if let v = d[key] { return v }
            for v in d.values { if let f = find(key, in: v) { return f } }
        } else if let a = o as? [Any] {
            for v in a { if let f = find(key, in: v) { return f } }
        }
        return nil
    }
    guard let status = find("status", in: obj) as? [String: Any], let name = status["name"] as? String else { return nil }
    let category = (status["statusCategory"] as? [String: Any])?["key"] as? String
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    let changed = (find("statuscategorychangedate", in: obj) as? String).flatMap(f.date)
    return (name, category == "done", changed?.timeIntervalSince1970)
}

func appleScriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// Brings the Terminal.app tab on this tty to the front; false if no tab has it.
func focusTerminalTab(_ tty: String) -> Bool {
    let script = """
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is \(appleScriptString(tty)) then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
    end tell
    return false
    """
    var err: NSDictionary?
    let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { log("focus tab failed: \(err)") }
    return r?.booleanValue ?? false
}

func resumeInTerminal(cwd: String, uuid: String) {
    let cmd = "cd \(shellQuote(cwd)) && claude --resume \(uuid)"
    let script = """
    tell application "Terminal"
        do script \(appleScriptString(cmd))
        activate
    end tell
    """
    var err: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { log("resume failed: \(err)") }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func appendRun(_ r: JudgeRun) {
    guard let line = try? JSONEncoder().encode(r) else { return }
    if let h = try? FileHandle(forWritingTo: judgeHistoryURL) {
        h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try? h.close()
    } else {
        try? (line + Data("\n".utf8)).write(to: judgeHistoryURL)
    }
}

func run(_ path: String, _ args: [String], stdin: String? = nil, stdout: FileHandle? = nil) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.currentDirectoryURL = dataDir
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = toolPATH
    p.environment = env
    let out = Pipe()
    p.standardOutput = stdout ?? out
    p.standardError = FileHandle.nullDevice
    let input = Pipe()
    if stdin != nil { p.standardInput = input }
    do { try p.run() } catch { return nil }
    if let s = stdin {
        input.fileHandleForWriting.write(s.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
    }
    let data = stdout == nil ? out.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
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

final class Store: ObservableObject {
    @Published var sessions: [Session] = [] {
        didSet { byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    private var byId: [String: Session] = [:]
    @Published var manual = Manual()
    @Published var judge: JudgeFile?
    @Published var judging = false
    @Published var triageNote: String?  // a short-lived word on the last Triage click
    @Published var integrations: [Integration] = []
    @Published var runs: [JudgeRun] = []
    @Published var days: [String] = []        // snapshot days, oldest first
    @Published var summarizing: String?       // the day Claude is summarizing
    private var lastSnapshotTasks: Data?
    private var summaryTried: [String: Date] = [:]  // day -> last auto attempt, retried after 30 min
    private var prLive: [String: (state: String, endedAt: Double?, author: String?)] = [:]  // PR url -> from gh
    private var repoByCwd: [String: String?] = [:]  // folder -> its GitHub "owner/repo", nil when not GitHub
    private var me: String?                         // the GitHub login, to tell own PRs from teammates'
    private var textRefs: [String: [String]] = [:]  // task id -> PRs it names, its own and in its text
    private(set) var teamReviews = Set<String>()    // tasks reviewing a teammate's PR
    private var tickets: [String: (status: String, done: Bool, changedAt: Double?)] = [:]  // Jira key -> from acli
    private var lastPrRefresh = Date.distantPast
    private var timer: Timer?
    private let loadQueue = DispatchQueue(label: "taskfloat.load", qos: .utility)
    // Transcript path -> what it held at that mtime. Touched only on loadQueue.
    private var transcriptCache: [String: (mtime: Double, terminal: Bool, session: Session?)] = [:]
    // Desktop session file path -> what it held at that mtime. Touched only on loadQueue.
    private var sessionCache: [String: (mtime: Double, session: Session)] = [:]
    // Transcript path -> the question it left open at that mtime. Touched only on loadQueue.
    private var askCache: [String: (mtime: Double, ask: String?)] = [:]

    init() {
        try? FileManager.default.createDirectory(at: daysDir, withIntermediateDirectories: true)
        refreshDays()
        if let data = try? Data(contentsOf: stateURL),
           var m = try? JSONDecoder().decode(Manual.self, from: data) {
            var marks = m.marks ?? [:]
            for (id, t) in m.doneAt where marks[id] == nil { marks[id] = Mark(at: t, reason: reasonManual, auto: false) }
            m.marks = marks
            m.doneAt = [:]
            manual = m
        }
        if let data = try? Data(contentsOf: judgeURL) { judge = try? JSONDecoder().decode(JudgeFile.self, from: data) }
        if let text = try? String(contentsOf: judgeHistoryURL, encoding: .utf8) {
            runs = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JudgeRun.self, from: Data($0.utf8)) }
        }
        reload()
        checkIntegrations()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
    }

    // MARK: Loading

    func reload() {
        loadQueue.async {
            var out: [Session] = self.loadTerminalSessions()
            var deletedAt: [String: Double] = [:]  // uuid -> ms
            let files = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey])
            while let url = files?.nextObject() as? URL {
                let name = url.lastPathComponent
                if name.hasPrefix("deleted_") {
                    let ms = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    deletedAt[String(name.dropFirst("deleted_".count))] = ms ?? 0
                    continue
                }
                guard name.hasPrefix("local_"), url.pathExtension == "json" else { continue }
                // Only files that changed since the last pass are read and parsed again.
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                if let cached = self.sessionCache[url.path], cached.mtime == mtime {
                    out.append(self.withPendingAsk(cached.session))
                    continue
                }
                guard let data = try? Data(contentsOf: url),
                      let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let summary = d["postTurnSummary"] as? [String: Any]
                let prs = (d["prs"] as? [[String: Any]] ?? []).compactMap { p -> PR? in
                    guard let u = p["url"] as? String else { return nil }
                    return PR(url: u, number: p["prNumber"] as? Int ?? 0, state: p["state"] as? String ?? "")
                }
                let runCwd = d["cwd"] as? String ?? ""
                let session = Session(
                    id: url.deletingPathExtension().lastPathComponent,
                    cliId: d["cliSessionId"] as? String,
                    title: d["title"] as? String ?? "(untitled)",
                    // originCwd is the repo a worktree session was started from.
                    cwd: d["originCwd"] as? String ?? runCwd,
                    runCwd: runCwd,
                    lastActivity: Date(timeIntervalSince1970: ((d["lastActivityAt"] as? Double) ?? 0) / 1000),
                    status: summary?["status_category"] as? String,
                    detail: summary?["status_detail"] as? String,
                    needs: summary?["needs_action"] as? String,
                    scheduledTaskId: d["scheduledTaskId"] as? String,
                    prs: prs,
                    archived: (d["isArchived"] as? Bool) == true,
                    deleted: false,
                    parentId: (d["spawnedFrom"] as? [String: Any])?["sessionId"] as? String,
                    startedAt: (d["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
                self.sessionCache[url.path] = (mtime, session)
                out.append(self.withPendingAsk(session))
            }
            out.sort { $0.lastActivity > $1.lastActivity }
            // Keep only the newest unarchived run of each scheduled task.
            var seenTasks = Set<String>()
            out = out.filter { s in
                guard let t = s.scheduledTaskId else { return true }
                return !s.archived && seenTasks.insert(t).inserted
            }
            DispatchQueue.main.async { self.apply(out, deletedAt: deletedAt) }
        }
        // Dropping a `run-now` file in the data folder starts a judge run (for scripts and schedules).
        let trigger = dataDir.appendingPathComponent("run-now")
        if !sessions.isEmpty, FileManager.default.fileExists(atPath: trigger.path) {
            try? FileManager.default.removeItem(at: trigger)
            runJudge()
        }
        // An `open-now` file holding a task id acts like clicking that row.
        let openTrigger = dataDir.appendingPathComponent("open-now")
        if !sessions.isEmpty, let id = try? String(contentsOf: openTrigger, encoding: .utf8) {
            try? FileManager.default.removeItem(at: openTrigger)
            open(id.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !sessions.isEmpty, Date().timeIntervalSince(lastPrRefresh) > prRefreshMinutes * 60 {
            lastPrRefresh = Date()
            refreshPRs()
        }
    }

    // What each outside tool can do for this user right now, for the Integrations panel.
    func checkIntegrations() {
        DispatchQueue.global(qos: .utility).async {
            let found = Integration.check()
            DispatchQueue.main.async { self.integrations = found }
        }
    }

    // Adds the question a desktop session's last turn left open, read again only when its
    // transcript changes. Archived and scheduled sessions are skipped: nobody's waiting there.
    private func withPendingAsk(_ s: Session) -> Session {
        guard !s.archived, s.scheduledTaskId == nil, let cli = s.cliId else { return s }
        let url = transcriptURL(cwd: s.runCwd, cliId: cli)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let ask: String?
        if let cached = askCache[url.path], cached.mtime == mtime {
            ask = cached.ask
        } else {
            ask = pendingQuestion(in: url)
            askCache[url.path] = (mtime, ask)
        }
        var s = s
        s.pendingAsk = ask
        return s
    }

    // Terminal sessions; each transcript is read in full only when it changes.
    private func loadTerminalSessions() -> [Session] {
        var found: [Session] = []
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                let cached = transcriptCache[url.path]
                if cached?.terminal == false { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                if let cached, cached.mtime == mtime {
                    if let s = cached.session { found.append(s) }
                    continue
                }
                var terminal = cached?.terminal
                if terminal == nil {
                    guard let e = transcriptEntrypoint(url) else { continue }  // still empty; look again later
                    terminal = e == "cli"
                }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                let s = terminal == true ? parseTerminalSession(url, mtime: mtime, created: created) : nil
                transcriptCache[url.path] = (mtime, terminal ?? false, s)
                if let s { found.append(s) }
            }
        }
        return found
    }

    // MARK: Opening a task

    // Desktop sessions open in the app; terminal ones switch to their Terminal tab when one
    // is running, else resume in a new tab. Never starts a second copy of a running session.
    func open(_ id: String) {
        guard !id.hasPrefix("cli_") else {
            guard let s = sessions.first(where: { $0.id == id }), !s.deleted, let uuid = s.cliId else { return }
            let newest = sessions.filter { $0.isTerminal && !$0.deleted && $0.runCwd == s.runCwd }
                .max { $0.lastActivity < $1.lastActivity }?.id == s.id
            DispatchQueue.global(qos: .userInitiated).async {
                let tty = runningTTY(for: s, newestInCwd: newest)
                DispatchQueue.main.async {
                    if let tty {
                        if !focusTerminalTab(tty) {
                            let a = NSAlert()
                            a.messageText = "This session is running, but not in Terminal.app"
                            a.informativeText = "It is on \(tty), perhaps in another terminal or the Claude app's terminal pane. Switch to it there."
                            a.runModal()
                        }
                    } else {
                        resumeInTerminal(cwd: s.runCwd, uuid: uuid)
                    }
                }
            }
            return
        }
        NSWorkspace.shared.open(URL(string: "claude://code/continue?session=\(id)")!)
    }

    // Layer 1 rules, plus layer 2 verdicts from the last Claude run.
    private func apply(_ loaded: [Session], deletedAt: [String: Double]) {
        var all = loaded
        var known = manual.known ?? [:]
        var marks = manual.marks ?? [:]
        let dismissed = manual.dismissed ?? []
        let now = Date().timeIntervalSince1970
        let ids = Set(loaded.map(\.id))

        for s in loaded where !s.archived && s.scheduledTaskId == nil {
            known[s.id] = Known(title: s.title, cwd: s.cwd)
        }
        // Tracked sessions whose file is gone were deleted.
        for (id, k) in known where !ids.contains(id) {
            let ms = deletedAt[String(id.dropFirst("local_".count))] ?? 0
            let at = ms > 0 ? ms / 1000 : now
            all.append(Session(id: id, cliId: nil, title: k.title, cwd: k.cwd, runCwd: k.cwd,
                               lastActivity: Date(timeIntervalSince1970: at), status: nil, detail: nil,
                               needs: nil, scheduledTaskId: nil, prs: [], archived: false, deleted: true))
            if marks[id] == nil { marks[id] = Mark(at: at, reason: reasonDeleted, auto: true) }
        }
        updateReviews(all)
        for s in all where known[s.id] != nil && !s.deleted {
            if s.archived {
                if marks[s.id] == nil { marks[s.id] = Mark(at: now, reason: reasonArchived, auto: true) }
            } else if marks[s.id]?.reason == reasonArchived {
                marks[s.id] = nil  // unarchived again
            } else if marks[s.id] == nil, !dismissed.contains(s.id), let reason = reviewEvidence(s) ?? ticketEvidence(s) ?? (ticketDecides(s) ? nil : prEvidence(s)) {
                // Dated to when the work stopped, so old tasks don't flood "Done today".
                marks[s.id] = Mark(at: s.lastActivity.timeIntervalSince1970, reason: reason, auto: true)
            }
        }
        if let j = judge {
            let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for v in j.verdicts where v.verdict == "done" && marks[v.id] == nil && !dismissed.contains(v.id) {
                // Only if nothing happened since Claude looked; a failed check leaves it a suggestion.
                if let s = byId[v.id], v.current(for: s, runAt: j.generatedAt), v.holds(lastActivity: s.lastActivity) {
                    marks[v.id] = Mark(at: now, reason: "Claude: " + v.reason, auto: true)
                }
            }
        }

        // Changes found by a refresh (a merged PR, a ticket gone Done, a new task) ease in too.
        withAnimation(Motion.refresh) {
            let changed = (manual.known ?? [:]) != known || (manual.marks ?? [:]).count != marks.count
            manual.known = known
            manual.marks = marks
            if changed { save() }
            // Unchanged data leaves the list alone, so a quiet refresh redraws nothing.
            let next = all.filter { !$0.archived || known[$0.id] != nil }
            if next != sessions { sessions = next }
        }
        writeTodaySnapshot()
        autoSummarize()
    }

    // MARK: Day snapshots

    private func snapshotURL(_ day: String) -> URL { daysDir.appendingPathComponent("\(day).json") }

    func loadSnapshot(_ day: String) -> DaySnapshot? {
        (try? Data(contentsOf: snapshotURL(day))).flatMap { try? JSONDecoder().decode(DaySnapshot.self, from: $0) }
    }

    private func saveSnapshot(_ snap: DaySnapshot) {
        try? JSONEncoder().encode(snap).write(to: snapshotURL(snap.day))
        refreshDays()
        objectWillChange.send()
    }

    private func refreshDays() {
        days = ((try? FileManager.default.contentsOfDirectory(atPath: daysDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    // Only today's file is ever rewritten from live data, so past days stay as they were.
    private func writeTodaySnapshot() {
        func snap(_ s: Session, _ section: String) -> SnapTask {
            SnapTask(id: s.id, title: s.title, project: s.project, section: section, detail: s.detail,
                     needs: s.nextStep, doneReason: section == "done" ? mark(s)?.reason : nil,
                     lastActivity: s.lastActivity.timeIntervalSince1970, deleted: s.deleted)
        }
        // Flat: nested children are recorded under their own section.
        let open = sessions.compactMap { s in baseSection(s).map { snap(s, $0) } }
        let blockedRuns = scheduled.filter(\.waiting).map { snap($0, "needsYou") }
        let tasks = open + blockedRuns + doneToday.map { snap($0, "done") }
        guard let data = try? JSONEncoder().encode(tasks), data != lastSnapshotTasks else { return }
        lastSnapshotTasks = data
        let day = dayKey(Date())
        var file = loadSnapshot(day) ?? DaySnapshot(day: day, updatedAt: 0, tasks: [])
        file.tasks = tasks
        file.updatedAt = Date().timeIntervalSince1970
        saveSnapshot(file)
    }

    // The user's corrections to a day; a value matching the snapshot drops the correction.
    func setDone(_ day: String, _ t: SnapTask, _ done: Bool) {
        guard var snap = loadSnapshot(day) else { return }
        var edits = snap.userDone ?? [:]
        edits[t.id] = done == (t.section == "done") ? nil : done
        snap.userDone = edits
        saveSnapshot(snap)
    }

    func setSummary(_ day: String, _ text: String) {
        guard var snap = loadSnapshot(day) else { return }
        snap.summary = text
        snap.summaryEdited = true
        saveSnapshot(snap)
    }

    // Recent past days left without a summary get one: right after midnight if the app is
    // running, else at the next launch. A failed try is retried after 30 minutes.
    private func autoSummarize() {
        guard summarizing == nil else { return }
        let today = dayKey(Date())
        let earliest = dayKey(Date().addingTimeInterval(-Double(autoSummaryDays) * 86400))
        guard let day = days.last(where: { d in
            d < today && d >= earliest && (summaryTried[d].map { Date().timeIntervalSince($0) > 1800 } ?? true)
        }), loadSnapshot(day)?.summary == nil else { return }
        summaryTried[day] = Date()
        summarize(day)
    }

    func summarize(_ day: String) {
        guard summarizing == nil, let snap = loadSnapshot(day), !snap.tasks.isEmpty else { return }
        let rows: [[String: Any]] = snap.tasks.map { t in
            ["title": t.title, "project": t.project, "section": t.section, "done": snap.isDone(t),
             "detail": t.detail ?? "", "needs": t.needs ?? "", "doneReason": t.doneReason ?? ""]
        }
        guard let json = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]))
            .flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        let prompt = """
        Below is a snapshot (JSON) of the user's Claude Code tasks on \(day). Sections: done = finished \
        that day, needsYou = waiting on the user, active = in progress, idle = untouched lately, \
        onHold = parked. The `done` field already includes the user's own corrections; trust it.

        Write the user a summary of that day for their own reference, in English, at most 80 words, \
        as up to three bullet points:
        - what got finished
        - what moved forward, and what is blocked
        - what to do first next
        Use only what the snapshot says; do not invent anything. Output the bullets only, no heading.

        \(json)
        """
        guard let claude = Tools.claude else { return }
        summarizing = day
        let started = Date().timeIntervalSince1970
        DispatchQueue.global(qos: .utility).async {
            let out = run(claude, [
                "-p", "--model", triageModel, "--output-format", "json", "--no-session-persistence",
                "--strict-mcp-config", "--max-budget-usd", "0.5", "--tools", "",
            ], stdin: prompt)
            let obj = out.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            var usage = JudgeRun(at: started, raw: obj)
            usage.kind = "summary"
            appendRun(usage)
            let text = (obj?["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.runs.append(usage)
                self.summarizing = nil
                // Reload: the user may have edited the day while Claude was writing.
                guard usage.ok, let text, !text.isEmpty, var snap = self.loadSnapshot(day) else { return }
                snap.summary = text
                snap.summaryAt = Date().timeIntervalSince1970
                snap.summaryEdited = false
                self.saveSnapshot(snap)
            }
        }
    }

    private func prEvidence(_ s: Session) -> String? {
        guard !s.prs.isEmpty else { return nil }
        let states = s.prs.map { prLive[$0.url]?.state ?? $0.state }
        guard states.allSatisfy({ $0 == "MERGED" || $0 == "CLOSED" }) else { return nil }
        // Needs gh's merge/close times; work after the last one means the task went on.
        let ends = s.prs.compactMap { prLive[$0.url]?.endedAt }
        guard ends.count == s.prs.count, let lastEnd = ends.max(),
              s.lastActivity.timeIntervalSince1970 <= lastEnd + prGraceHours * 3600 else { return nil }
        let nums = s.prs.map { "#\($0.number)" }.joined(separator: " ")
        return states.contains("MERGED") ? "PR \(nums) merged" : "PR \(nums) closed"
    }

    // A team code review: the task talks about a review, and names someone else's PR. Done once
    // those teammates' PRs are merged or closed; the ticket behind them doesn't matter here.
    // The user's own PRs are left out: the app links a folder's current-branch PR to every
    // session run there, so an own PR on a review task is usually just that.
    private func reviewEvidence(_ s: Session) -> String? {
        guard teamReviews.contains(s.id), let me else { return nil }
        let refs = (textRefs[s.id] ?? []).filter { prLive[$0]?.author.map { $0 != me } ?? false }
        let known = refs.compactMap { prLive[$0] }.filter { $0.state != "UNKNOWN" }
        guard !known.isEmpty, known.allSatisfy({ $0.state == "MERGED" || $0.state == "CLOSED" }),
              let lastEnd = known.compactMap(\.endedAt).max(),
              s.lastActivity.timeIntervalSince1970 <= lastEnd + prGraceHours * 3600 else { return nil }
        let nums = refs.compactMap { $0.split(separator: "/").last.map { "#\($0)" } }.joined(separator: " ")
        return known.contains { $0.state == "MERGED" } ? "Team review: PR \(nums) merged" : "Team review: PR \(nums) closed"
    }

    // Own work on a ticket: Jira decides. Done once the ticket is in Jira's Done category and the
    // session hasn't been worked in since it got there.
    private func ticketEvidence(_ s: Session) -> String? {
        guard !teamReviews.contains(s.id), let key = ticketKey(s.title), let t = tickets[key], t.done else { return nil }
        if let c = t.changedAt, s.lastActivity.timeIntervalSince1970 > c + prGraceHours * 3600 { return nil }
        return "Ticket \(key) \(t.status)"
    }

    // Whether Jira, not PRs, settles this task: own work whose ticket acli could read.
    private func ticketDecides(_ s: Session) -> Bool {
        !teamReviews.contains(s.id) && ticketKey(s.title).flatMap { tickets[$0] } != nil
    }

    // The ticket's current status, for the footer line of own work.
    func ticketStatus(_ s: Session) -> String? {
        guard !teamReviews.contains(s.id), let key = ticketKey(s.title) else { return nil }
        return tickets[key]?.status
    }

    private func reviewText(_ s: Session) -> String { [s.title, s.detail ?? "", s.needs ?? ""].joined(separator: "\n") }

    // Which PRs each open task names, and which tasks are team code reviews.
    private func updateReviews(_ all: [Session]) {
        var refs: [String: [String]] = [:], team = Set<String>()
        for s in all where !s.archived && !s.deleted && s.scheduledTaskId == nil {
            // Named by convention ("Team code review: …"): certain, no PR lookup needed.
            let named = namedTeamReview(s.title)
            if named { team.insert(s.id) }
            let r = Array(Set(s.prs.map(\.url) + prRefs(in: reviewText(s), repo: repoByCwd[s.cwd] ?? nil,
                                                       defaultOwner: config.githubOrg ?? commonOwner(repoByCwd))))
            guard !r.isEmpty else { continue }
            refs[s.id] = r
            // Otherwise guessed, for sessions named before the convention: talk of a review
            // plus a PR by someone else.
            let authors = r.compactMap { prLive[$0]?.author }
            if !named, let me, reviewText(s).range(of: "review", options: .caseInsensitive) != nil,
               authors.contains(where: { $0 != me }) { team.insert(s.id) }
        }
        textRefs = refs
        teamReviews = team
    }

    private func refreshPRs() {
        // Open tasks' PRs, their own and those named in their text. Open ones may have changed;
        // finished ones need their merge time once; ones gh can't find are not asked again.
        let open = sessions.filter { !$0.archived && !$0.deleted && !isDone($0) && !isOnHold($0) && $0.scheduledTaskId == nil }
        let folders = Set(open.map(\.cwd)).filter { repoByCwd[$0] == nil }
        let live = prLive, knownRepos = repoByCwd, needMe = me == nil
        // Own work's tickets, read with the Atlassian CLI when it is installed; their status can
        // move either way, so every one is read again each time.
        let keys = Set(open.filter { !teamReviews.contains($0.id) }.compactMap { ticketKey($0.title) })
        let gh = Tools.gh, acliPath = Tools.acli  // either may be missing; its checks are then skipped
        DispatchQueue.global(qos: .utility).async {
            var foundTickets: [String: (status: String, done: Bool, changedAt: Double?)] = [:]
            if let acli = acliPath {
                for k in keys {
                    let out = shell(acli, ["jira", "workitem", "view", k, "--json", "--fields", "status,statuscategorychangedate"])
                    if let t = parseTicket(out) { foundTickets[k] = t } else { log("acli: no status for \(k)") }
                }
                log("acli: read \(foundTickets.count) of \(keys.count) tickets: \(foundTickets.keys.sorted().joined(separator: " "))")
            }
            var repos = knownRepos
            for f in folders { repos[f] = .some(githubRepo(of: f)) }
            let login = needMe ? gh.map { shell($0, ["api", "user", "-q", ".login"]).trimmingCharacters(in: .whitespacesAndNewlines) } : nil
            let owner = config.githubOrg ?? commonOwner(repos)
            let urls = Set(open.flatMap { s in
                s.prs.map(\.url) + prRefs(in: [s.title, s.detail ?? "", s.needs ?? ""].joined(separator: "\n"),
                                          repo: repos[s.cwd] ?? nil, defaultOwner: owner)
            }).filter { gh != nil && (live[$0] == nil || live[$0]?.state == "OPEN") }
            var found: [String: (state: String, endedAt: Double?, author: String?)] = [:]
            let iso = ISO8601DateFormatter()
            for u in urls {
                guard let gh, let out = run(gh, ["pr", "view", u, "--json", "state,mergedAt,closedAt,author"]),
                      let o = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
                      let state = o["state"] as? String else {
                    found[u] = ("UNKNOWN", nil, nil)
                    continue
                }
                let end = (o["mergedAt"] as? String).flatMap(iso.date) ?? (o["closedAt"] as? String).flatMap(iso.date)
                found[u] = (state, end?.timeIntervalSince1970, (o["author"] as? [String: Any])?["login"] as? String)
            }
            DispatchQueue.main.async {
                self.repoByCwd = repos
                if let login, !login.isEmpty { self.me = login }
                self.prLive.merge(found) { _, new in new }
                self.tickets.merge(foundTickets) { _, new in new }
                self.reload()
            }
        }
    }

    // MARK: Marks

    func mark(_ s: Session) -> Mark? { manual.marks?[s.id] }

    // Done unless the session saw activity after it was marked (work resumed).
    func isDone(_ s: Session) -> Bool {
        guard let m = mark(s) else { return false }
        return s.deleted || s.archived || s.lastActivity.timeIntervalSince1970 <= m.at + 60
    }

    func isPinned(_ s: Session) -> Bool { manual.pinned?.contains(s.id) ?? false }

    // On hold until the user resumes it, or works in the session again.
    func isOnHold(_ s: Session) -> Bool {
        guard let at = manual.onHold?[s.id], !isDone(s) else { return false }
        return s.lastActivity.timeIntervalSince1970 <= at + 60
    }

    func toggleHold(_ s: Session) {
        withAnimation(Motion.change) {
            manual.onHold?[s.id] = isOnHold(s) ? nil : Date().timeIntervalSince1970
            save()
        }
    }

    func toggleDone(_ s: Session) {
        withAnimation(Motion.change) {
            if isDone(s) {
                // Undoing an auto mark also stops the rules from marking it again.
                if mark(s)?.auto == true { manual.dismissed = (manual.dismissed ?? []).union([s.id]) }
                manual.marks?[s.id] = nil
            } else {
                manual.marks?[s.id] = Mark(at: Date().timeIntervalSince1970, reason: reasonManual, auto: false)
            }
            save()
        }
    }

    func togglePin(_ s: Session) {
        withAnimation(Motion.change) {
            var p = manual.pinned ?? []
            if p.contains(s.id) { p.remove(s.id) } else { p.insert(s.id) }
            manual.pinned = p
            save()
        }
    }

    func markAllDone(_ items: [Session]) {
        withAnimation(Motion.change) {
            let now = Date().timeIntervalSince1970
            for s in items { manual.marks?[s.id] = Mark(at: now, reason: reasonManual, auto: false) }
            save()
        }
    }

    // MARK: Suggestions (layer 3)

    func suggestion(_ s: Session) -> String? {
        guard let j = judge, !isDone(s), !isOnHold(s), !(manual.dismissed ?? []).contains("s:" + s.id),
              let v = j.verdicts.first(where: { $0.id == s.id && ["suggest_done", "done"].contains($0.verdict) }),
              v.current(for: s, runAt: j.generatedAt)
        else { return nil }
        // A done verdict that failed its check lands here too.
        return v.verdict == "done" ? v.reason + " (but you kept working after the merge)" : v.reason
    }

    // Triage's one-line verdict on a task it judged still active; gone once the session moves on.
    func verdictNote(_ s: Session) -> String? {
        guard let j = judge, !isDone(s),
              let v = j.verdicts.first(where: { $0.id == s.id && $0.verdict == "active" }),
              v.current(for: s, runAt: j.generatedAt) else { return nil }
        return v.reason
    }

    func acceptSuggestion(_ s: Session) {
        withAnimation(Motion.change) {
            manual.marks?[s.id] = Mark(at: Date().timeIntervalSince1970,
                                       reason: "Accepted Claude's suggestion: " + (suggestion(s) ?? ""), auto: false)
            save()
        }
    }

    func ignoreSuggestion(_ s: Session) {
        withAnimation(Motion.change) {
            manual.dismissed = (manual.dismissed ?? []).union(["s:" + s.id])
            save()
        }
    }

    private func save() {
        try? JSONEncoder().encode(manual).write(to: stateURL)
        objectWillChange.send()
    }

    // MARK: Claude judge (layers 2 and 3)

    // A task goes back to Claude only when its verdict is missing, stale (the session moved
    // since), or a day old: the last catches changes outside the session, like a PR merged by someone else.
    private func needsTriage(_ s: Session) -> Bool {
        guard let j = judge, let v = j.verdicts.first(where: { $0.id == s.id }) else { return true }
        let age = Date().timeIntervalSince1970 - (v.at ?? j.generatedAt)
        return !v.current(for: s, runAt: j.generatedAt) || age > reverifyHours * 3600
    }

    func runJudge(all: Bool = false) {
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
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = tasks.map { s in
            [
                "id": s.id, "title": s.title, "project": s.project,
                "source": s.isTerminal ? "terminal (no status summary; detail is the user's last prompt)" : "desktop",
                "kind": teamReviews.contains(s.id) ? "team code review" : "own work",
                "ticket": ticketKey(s.title).map { k in tickets[k].map { "\(k): \($0.status)" } ?? k } ?? "",
                "status": s.pendingAsk != nil ? "blocked" : s.status ?? "", "detail": s.detail ?? "", "needs": s.nextStep ?? "",
                "lastActivity": iso.string(from: s.lastActivity),
                "prs": s.prs.map { ["url": $0.url, "recordedState": prLive[$0.url]?.state ?? $0.state] },
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]),
              (try? data.write(to: openTasksURL)) != nil,
              let promptURL = Bundle.main.url(forResource: "judge-prompt", withExtension: "md"),
              let template = try? String(contentsOf: promptURL, encoding: .utf8) else {
            finishJudge(JudgeFile(generatedAt: Date().timeIntervalSince1970, verdicts: [],
                                  error: "Couldn't write the task list or find judge-prompt.md"))
            return
        }
        let prompt = template.replacingOccurrences(of: "{{TASKS_FILE}}", with: openTasksURL.path)
        let schema = #"{"type":"object","properties":{"verdicts":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"verdict":{"enum":["done","suggest_done","active"]},"reason":{"type":"string"},"endedAt":{"type":"string"}},"required":["id","verdict","reason","endedAt"]}}},"required":["verdicts"]}"#
        guard let claude = Tools.claude else {
            finishJudge(JudgeFile(generatedAt: Date().timeIntervalSince1970, verdicts: [],
                                  error: "Claude CLI not found: install Claude Code, or set claudePath in config.json"))
            return
        }
        let started = Date().timeIntervalSince1970
        judging = true
        let titles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .utility).async {
            // Every step streams to the trace; its last "result" line is what the run returned.
            FileManager.default.createFile(atPath: judgeTraceURL.path, contents: nil)
            let out = try? FileHandle(forWritingTo: judgeTraceURL)
            _ = run(claude, [
                "-p", "--model", triageModel, "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                "--strict-mcp-config", "--max-budget-usd", "2", "--json-schema", schema,
                // Status only: the task list and gh, no transcripts.
                "--tools", "Read", "Bash", "--allowedTools", "Read", "Bash(gh pr view:*)",
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

    // MARK: Sections

    private var openTasks: [Session] {
        sessions.filter { $0.scheduledTaskId == nil && !$0.archived && !$0.deleted && !isDone($0) }
    }
    private func recent(_ s: Session) -> Bool { s.age <= activeHours * 3600 || isPinned(s) }
    private func within(_ s: Session, days: Double) -> Bool { s.age <= days * 86400 }

    // The section a task belongs to on its own, or nil when it is done or scheduled.
    private func baseSection(_ s: Session) -> String? {
        guard s.scheduledTaskId == nil, !s.archived, !s.deleted, !isDone(s) else { return nil }
        if isOnHold(s) { return "onHold" }
        if s.waiting && within(s, days: blockedDays) { return "needsYou" }
        if recent(s) { return "active" }
        return "idle"
    }

    // A session started from a listed parent shows under that parent instead of on its own.
    private func isNested(_ s: Session) -> Bool {
        guard let p = s.parentId, let parent = byId[p] else { return false }
        return baseSection(parent) != nil
    }

    func children(of s: Session) -> [Session] { openTasks.filter { $0.parentId == s.id } }

    // A section's top-level tasks, newest first. A task with children sorts by its family's
    // newest activity, so a child's fresh progress lifts the whole family. And when a child is
    // waiting on the user, its whole family moves up to "Needs you" (from In progress or Idle;
    // a family the user put on hold stays there).
    private func top(_ section: String) -> [Session] {
        var newestChild: [String: Date] = [:], childWaits = Set<String>()
        for c in openTasks {
            guard let p = c.parentId else { continue }
            newestChild[p] = max(newestChild[p] ?? .distantPast, c.lastActivity)
            if baseSection(c) == "needsYou" { childWaits.insert(p) }
        }
        let latest = { (s: Session) in max(s.lastActivity, newestChild[s.id] ?? .distantPast) }
        let familySection = { (s: Session) -> String? in
            let own = self.baseSection(s)
            return (own == "active" || own == "idle") && childWaits.contains(s.id) ? "needsYou" : own
        }
        return sessions.filter { familySection($0) == section && !isNested($0) }.sorted { latest($0) > latest($1) }
    }

    var needsYou: [Session] { top("needsYou") + scheduled.filter(\.waiting) }
    var active: [Session] { top("active") }
    var idle: [Session] { top("idle") }
    var onHold: [Session] { top("onHold") }
    var scheduled: [Session] {
        sessions.filter { $0.scheduledTaskId != nil && !isDone($0) && within($0, days: scheduledDays) }
    }

    // What Triage looks at: "Needs you" and "In progress", with their open children. Idle,
    // on-hold and scheduled tasks are skipped.
    var judged: [Session] {
        let listed = needsYou + active
        let kids = listed.flatMap(children(of:)).filter { baseSection($0) == "needsYou" || baseSection($0) == "active" }
        return (listed + kids).filter { $0.scheduledTaskId == nil }
    }
    var doneToday: [Session] {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return sessions.filter { isDone($0) && (mark($0)?.at ?? 0) >= start }
            .sorted { (mark($0)?.at ?? 0) > (mark($1)?.at ?? 0) }
    }

    // Whether a source's badge stays quiet (a grey icon) rather than a coloured pill. The source
    // most open tasks come from goes quiet, so the rarer one stands out; when neither is rare
    // (the smaller side is a third or more), both keep their pills.
    func badgeIsQuiet(terminal: Bool) -> Bool {
        let open = openTasks
        guard !open.isEmpty else { return false }
        let terminalShare = Double(open.filter(\.isTerminal).count) / Double(open.count)
        if terminalShare < 1.0 / 3 { return !terminal }
        if terminalShare > 2.0 / 3 { return terminal }
        return false
    }

    // The colour a task's dot takes, matching its section header.
    func tint(_ s: Session) -> Color {
        if s.deleted { return .gray.opacity(0.4) }
        if isDone(s) { return Palette.done }
        if isOnHold(s) { return Palette.onHold }
        if s.waiting { return Palette.needsYou }
        if s.scheduledTaskId != nil { return Palette.scheduled }
        return recent(s) ? Palette.active : Palette.idle
    }
}

// MARK: - Look

// How the list moves: a short, soft spring for the user's own actions, a gentler ease for
// changes a refresh brings in, so nothing jumps.
enum Motion {
    static let change = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let refresh = Animation.easeInOut(duration: 0.35)
    // A row leaving slides out to the side; one arriving drops in from just above.
    static let row = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: -6)),
        removal: .move(edge: .trailing).combined(with: .opacity))
}

enum Palette {
    static let needsYou = Color.orange
    static let active = Color.blue
    static let idle = Color.gray
    static let onHold = Color.indigo
    static let scheduled = Color.teal
    static let done = Color.green
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)  // the App badge
    static let terminal = Color(red: 0.35, green: 0.55, blue: 0.40) // the Terminal badge
    static let suggestion = Color.purple
    static let review = Color.pink  // the "Team code review" title prefix
}

// The kinds of text whose size the user can set. Smaller text that goes with a kind (the
// badge next to the footer line, the count next to a section title) follows it by an offset.
enum TextRole: String, CaseIterable, Identifiable {
    case title, detail, meta, header, count
    var id: String { rawValue }

    var base: CGFloat {
        switch self {
        case .title: return 12.5
        case .detail: return 11
        case .meta: return 10
        case .header: return 12
        case .count: return 16
        }
    }

    var label: String {
        switch self {
        case .title: return "Task titles"
        case .detail: return "Status lines"
        case .meta: return "Footer line"
        case .header: return "Section titles"
        case .count: return "Counts"
        }
    }

    var hint: String {
        switch self {
        case .title: return "The bold name of each task"
        case .detail: return "Status, next step and Claude's suggestions"
        case .meta: return "App or Terminal badge, project, time"
        case .header: return "Section names and their counts"
        case .count: return "The numbers in the strip at the top"
        }
    }

    var sample: String {
        switch self {
        case .title: return "PROJ-123 Fix the export dialog's progress bar"
        case .detail: return "PR #42 review posted; awaiting approval"
        case .meta: return "web-app · 1 hr. ago · 2d 4h"
        case .header: return "In progress"
        case .count: return "9"
        }
    }
}

// The user's text sizes, kept in UserDefaults. Views observe it, so a change applies at once.
final class TextSizes: ObservableObject {
    static let shared = TextSizes()
    static let range: ClosedRange<CGFloat> = -3...8  // how far each kind may move from its default
    private let key = "textSizes"
    @Published private(set) var sizes: [String: Double]

    init() { sizes = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }

    func size(_ role: TextRole) -> CGFloat { sizes[role.rawValue].map { CGFloat($0) } ?? role.base }

    // A size for text that goes with a kind: its size plus an offset, never below 7pt.
    func pt(_ role: TextRole, _ offset: CGFloat = 0) -> CGFloat { max(size(role) + offset, 7) }

    func step(_ role: TextRole, by delta: CGFloat) {
        let next = min(max(size(role) + delta, role.base + Self.range.lowerBound), role.base + Self.range.upperBound)
        sizes[role.rawValue] = Double(next)
        UserDefaults.standard.set(sizes, forKey: key)
    }

    var isDefault: Bool { TextRole.allCases.allSatisfy { size($0) == $0.base } }

    func reset() {
        sizes = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// Puts the enclosing scroll view on thin overlay scrollers that show only while scrolling,
// whatever the system's "Show scroll bars" setting says, so the list has no permanent bar.
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The system resets the style when that setting (or the attached mouse) changes.
            observer = observer ?? NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.apply() }
        }

        func apply() {
            DispatchQueue.main.async {
                guard let scroll = self.enclosingScrollView else { return }
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }
}

extension View {
    func overlayScrollers() -> some View { background(OverlayScrollers()) }

    // The grey the cards sit on: a touch darker than the window in light mode, lighter in dark.
    func canvas() -> some View {
        background(Color.primary.opacity(0.04)).background(Color(nsColor: .windowBackgroundColor))
    }
}

// Where a task runs: the Claude desktop app, or `claude` in a terminal. A quiet badge is just
// a grey icon, for the source most tasks share; the other is a coloured pill.
struct SourceBadge: View {
    @ObservedObject private var sizes = TextSizes.shared
    let terminal: Bool
    var quiet = false

    var body: some View {
        let color = terminal ? Palette.terminal : Palette.claude
        if quiet {
            Image(systemName: terminal ? "terminal" : "macwindow")
                .font(.system(size: sizes.pt(.meta, -0.5)))
                .foregroundStyle(.tertiary)
                .help(terminal ? "Terminal" : "Claude app")
        } else {
            pill(color)
        }
    }

    private func pill(_ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: terminal ? "terminal" : "macwindow")
                .font(.system(size: sizes.pt(.meta, -2), weight: .semibold))
            Text(terminal ? "Terminal" : "App")
                .font(.system(size: sizes.pt(.meta, -1), weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

// The Triage button: a compact pill in Claude's coral.
struct TriageButton: View {
    let running: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if running {
                    ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.8).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold))
                }
                Text(running ? "Triaging…" : "Triage").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(Palette.claude.opacity(running ? 0.7 : hovering ? 0.88 : 1)))
        }
        .buttonStyle(.plain)
        .disabled(running)
        .onHover { hovering = $0 }
    }
}

// A small hint that appears under a control after a short hover. Used where the system tooltip
// may not show, since this panel never becomes the active window.
struct HoverHint: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                guard inside else { withAnimation(.easeOut(duration: 0.1)) { shown = false }; return }
                let show = DispatchWorkItem { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
                pending = show
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: show)
            }
            .overlay(alignment: .topTrailing) {
                if shown {
                    Text(text)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 210, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .offset(y: 26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

extension View {
    func hoverHint(_ text: String) -> some View { modifier(HoverHint(text: text)) }
}

// A small icon button. With a tint it becomes a coloured disc in that section's colour,
// deepening on hover, like the count strip's numbers.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if let tint {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(tint.opacity(hovering ? 0.3 : 0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        } else {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .help(help)
        }
    }
}

// Set while rendering for a visual check, so hover-only controls show in the picture.
final class RenderCheck: ObservableObject {
    static let shared = RenderCheck()
    @Published var showActions = false
    @Published var jump: String?  // a section title, as if its count were clicked
    @Published var settings = false  // shows the text-size page while rendering
}

// The corner joining a nested row to its parent, as in the Claude app's sidebar.
struct Elbow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 3))
        p.addQuadCurve(to: CGPoint(x: r.minX + 3, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}

// The shared shape of a task row: dot, title, body lines, then the badge and meta line.
// Actions appear on hover, floating over the row's top-right corner.
struct RowShell<Lines: View, Actions: View>: View {
    @ObservedObject private var sizes = TextSizes.shared
    var nested = false
    let tint: Color
    let title: String
    var titlePrefix: String? = nil  // a coloured label read as part of the title, e.g. "Team code review"
    let titleDone: Bool
    let dimmed: Bool
    let pinned: Bool
    let terminal: Bool
    var quietBadge = false
    let meta: String
    var duration: String? = nil  // how long the session has run, shown with a timer icon
    let clickable: Bool
    let help: String
    let onOpen: () -> Void
    @ViewBuilder let lines: () -> Lines
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false
    @ObservedObject private var renderCheck = RenderCheck.shared

    // Title and body lines beside the dot; below them, flush with the dot, the footer line:
    // badge and meta on the left, the hover actions on the right where they cover nothing.
    var body: some View {
        let showActions = hovering || renderCheck.showActions
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                if nested {
                    Elbow().stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                        .frame(width: 9, height: 9).padding(.leading, 3)
                }
                Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ((titlePrefix.map { Text($0 + " · ").foregroundColor(Palette.review) } ?? Text(""))
                            + Text(title).strikethrough(titleDone).foregroundColor(dimmed ? .secondary : .primary))
                            .font(.system(size: sizes.pt(.title), weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if pinned {
                            Image(systemName: "pin.fill").font(.system(size: sizes.pt(.title, -4.5))).foregroundStyle(.tertiary)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    lines()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                SourceBadge(terminal: terminal, quiet: quietBadge)
                Text(meta).font(.system(size: sizes.pt(.meta))).foregroundStyle(.tertiary).lineLimit(1)
                if let duration {
                    Text("\(Image(systemName: "timer")) \(duration)")
                        .font(.system(size: sizes.pt(.meta))).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                        .help("From the session's start to its last activity")
                }
                Spacer(minLength: 4)
                // Always laid out, so the line doesn't shift when they appear.
                HStack(spacing: 3) { actions() }
                    .opacity(showActions ? 1 : 0)
                    .allowsHitTesting(showActions)
            }
            .padding(.leading, nested ? 21 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(showActions ? tint.opacity(0.07) : .clear)  // a faint wash of the row's section colour
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if clickable { onOpen() } }
        .help(help)
    }
}

// A section's rows on one rounded card, full-width hairlines between them, so each group reads
// as a unit against the window's grey.
struct Card<Item: Identifiable, RowView: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> RowView

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                // One unit per row, its divider included, so rows fade in and out whole.
                VStack(spacing: 0) {
                    if i > 0 { Divider() }
                    row(item)
                }
                .transition(Motion.row)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
        .padding(.horizontal, 10)
    }
}

// A row in a card: a task, or a child session nested under the task before it.
struct Entry: Identifiable {
    let session: Session
    let nested: Bool
    var id: String { session.id }
}

func openHelp(deleted: Bool, terminal: Bool) -> String {
    if deleted { return "This session was deleted" }
    return terminal ? "Switch to its Terminal tab, or resume it in a new one" : "Open in the Claude app"
}

struct Row: View {
    @ObservedObject private var sizes = TextSizes.shared
    let s: Session
    @ObservedObject var store: Store
    var nested = false

    private var teamReview: Bool { store.teamReviews.contains(s.id) }

    // Under the coloured "Team code review" prefix, a title's own opener ("Team code review:",
    // "Code review", "PR review") would repeat it.
    private func reviewTitle(_ t: String) -> String {
        guard let r = t.range(of: #"^(team\s+)?(code|pr)\s+review\b\s*[:·\-–]?\s*"#,
                              options: [.regularExpression, .caseInsensitive])
        else { return t }
        return String(t[r.upperBound...])
    }

    var body: some View {
        let done = store.isDone(s)
        RowShell(
            nested: nested, tint: store.tint(s), title: teamReview ? reviewTitle(s.title) : s.title,
            titlePrefix: teamReview ? "Team code review" : nil,
            titleDone: done, dimmed: done || s.deleted,
            pinned: store.isPinned(s) && !done, terminal: s.isTerminal,
            quietBadge: store.badgeIsQuiet(terminal: s.isTerminal), meta: meta,
            duration: s.startedAt.map { span(s.lastActivity.timeIntervalSince($0)) }, clickable: !s.deleted,
            help: openHelp(deleted: s.deleted, terminal: s.isTerminal), onOpen: { store.open(s.id) }
        ) {
            if done, let m = store.mark(s) {
                Label((m.auto ? "Auto · " : "") + m.reason, systemImage: "checkmark.circle")
                    .font(.system(size: sizes.pt(.detail))).foregroundStyle(.secondary).lineLimit(2)
            }
            if let d = s.detail, !done {
                Text(d).font(.system(size: sizes.pt(.detail))).foregroundStyle(.secondary).lineLimit(2)
            }
            if let n = s.nextStep, !done, s.waiting {
                Label(n, systemImage: "arrow.turn.down.right")
                    .font(.system(size: sizes.pt(.detail))).foregroundStyle(Palette.needsYou).lineLimit(2)
            }
            if let note = store.verdictNote(s) {
                Label {
                    Text(note)
                } icon: {
                    Image(systemName: "sparkles").font(.system(size: sizes.pt(.detail, -1.5)))
                }
                .font(.system(size: sizes.pt(.detail))).foregroundStyle(Palette.suggestion.opacity(0.85))
                .lineLimit(2)
                .help("Triage's verdict")
            }
            if let reason = store.suggestion(s) {
                SuggestionCallout(reason: reason, accept: { store.acceptSuggestion(s) },
                                  dismiss: { store.ignoreSuggestion(s) })
            }
        } actions: {
            if !done && s.scheduledTaskId == nil {
                let held = store.isOnHold(s)
                if !held {
                    IconButton(symbol: store.isPinned(s) ? "pin.slash.fill" : "pin.fill",
                               help: store.isPinned(s) ? "Unpin" : "Pin to In progress, however long it sits",
                               tint: Palette.active) {
                        store.togglePin(s)
                    }
                }
                IconButton(symbol: held ? "play.fill" : "pause.fill",
                           help: held ? "Resume" : "Put on hold: not now, and Claude skips it",
                           tint: held ? Palette.active : Palette.onHold) { store.toggleHold(s) }
            }
            if !s.deleted && !s.archived {
                IconButton(symbol: done ? "arrow.uturn.backward" : "checkmark",
                           help: done ? "Undo" : "Mark done",
                           tint: done ? Palette.needsYou : Palette.done) { store.toggleDone(s) }
            }
        }
    }

    private var meta: String {
        let where_ = [s.project, s.branch, store.ticketStatus(s)].compactMap { $0 }.joined(separator: " · ")
        if s.deleted { return where_ + " · deleted" }
        let carried = s.lastActivity < Calendar.current.startOfDay(for: Date()) && !store.isDone(s) ? " · carried over" : ""
        return "\(where_) · \(relative(s.lastActivity))\(carried)"
    }
}

struct SuggestionCallout: View {
    @ObservedObject private var sizes = TextSizes.shared
    let reason: String
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: sizes.pt(.detail, -1))).foregroundStyle(Palette.suggestion).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude suggests wrapping up: " + reason)
                    .font(.system(size: sizes.pt(.detail))).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Wrap up", action: accept).foregroundStyle(Palette.suggestion)
                    Button("Dismiss", action: dismiss).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).font(.system(size: sizes.pt(.detail, -0.5), weight: .semibold))
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.suggestion.opacity(0.08)))
        .padding(.top, 2)
    }
}

struct SectionHeader: View {
    @ObservedObject private var sizes = TextSizes.shared
    let title: String
    let count: Int
    let tint: Color
    let collapsible: Bool
    let open: Bool
    var trailing: (label: String, action: () -> Void)? = nil
    let toggle: () -> Void

    // Sits on the window's grey above its card, and stays pinned there while the card scrolls.
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: sizes.pt(.header), weight: .bold)).foregroundStyle(.primary)
            Text("\(count)")
                .font(.system(size: sizes.pt(.header, -2), weight: .bold)).monospacedDigit()
                .foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.15)))
            if collapsible {
                Image(systemName: "chevron.right").font(.system(size: sizes.pt(.header, -3), weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            Spacer()
            if let trailing, open {
                Button(trailing.label, action: trailing.action)
                    .buttonStyle(.borderless).font(.system(size: sizes.pt(.header, -1.5), weight: .medium))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .canvas()
        .contentShape(Rectangle())
        .onTapGesture { if collapsible { toggle() } }
    }
}

// A day's Claude summary: generate, regenerate, or edit by hand.
struct SummaryBox: View {
    @ObservedObject private var sizes = TextSizes.shared
    let day: String
    @ObservedObject var store: Store
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let snap = store.loadSnapshot(day)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Palette.suggestion)
                Text("DAY SUMMARY").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                if snap?.summaryEdited == true {
                    Text("edited").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer()
                if store.summarizing == day {
                    ProgressView().controlSize(.mini)
                    Text("Summarizing…").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if editing {
                    Button("Save") { store.setSummary(day, draft); editing = false }
                    Button("Cancel") { editing = false }
                } else if snap != nil {
                    if snap?.summary != nil {
                        Button("Edit") { draft = snap?.summary ?? ""; editing = true }
                    }
                    Button(snap?.summary == nil ? "Summarize" : "Regenerate") { store.summarize(day) }
                        .help(snap?.summaryEdited == true ? "Replaces your edited summary" : "")
                }
            }
            .buttonStyle(.borderless).font(.system(size: 10, weight: .medium))
            if editing {
                TextEditor(text: $draft).font(.system(size: sizes.pt(.detail))).frame(height: 90)
            } else if let text = snap?.summary {
                Text(text).font(.system(size: sizes.pt(.detail, 0.5))).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if snap == nil {
                Text("No snapshot for this day").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.suggestion.opacity(0.06)))
        .padding(.horizontal, 12).padding(.top, 12)
    }
}

// A task in a past day's snapshot. Corrections are recorded on that day only.
struct SnapRow: View {
    @ObservedObject private var sizes = TextSizes.shared
    let t: SnapTask
    let day: String
    let snap: DaySnapshot
    @ObservedObject var store: Store

    var body: some View {
        let done = snap.isDone(t)
        let corrected = snap.userDone?[t.id] != nil
        let terminal = t.id.hasPrefix("cli_")
        let tint: Color = t.deleted ? .gray.opacity(0.4) : done ? Palette.done
            : ["needsYou": Palette.needsYou, "active": Palette.active, "onHold": Palette.onHold][t.section] ?? Palette.idle
        RowShell(
            tint: tint, title: t.title, titleDone: done, dimmed: done || t.deleted, pinned: false,
            terminal: terminal, quietBadge: store.badgeIsQuiet(terminal: terminal),
            meta: t.project + (t.deleted ? " · deleted" : "") + (corrected ? " · corrected by hand" : ""),
            clickable: !t.deleted, help: openHelp(deleted: t.deleted, terminal: terminal),
            onOpen: { store.open(t.id) }
        ) {
            if done {
                Label(t.doneReason ?? "Marked done by hand", systemImage: "checkmark.circle")
                    .font(.system(size: sizes.pt(.detail))).foregroundStyle(.secondary).lineLimit(2)
            } else if let d = t.detail {
                Text(d).font(.system(size: sizes.pt(.detail))).foregroundStyle(.secondary).lineLimit(2)
            }
        } actions: {
            IconButton(symbol: done ? "arrow.uturn.backward" : "checkmark",
                       help: done ? "Not done that day" : "Mark done that day",
                       tint: done ? Palette.needsYou : Palette.done) { store.setDone(day, t, !done) }
        }
    }
}

// A past day, read from its snapshot.
struct DayView: View {
    let day: String
    @ObservedObject var store: Store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                SummaryBox(day: day, store: store)
                if let snap = store.loadSnapshot(day) {
                    let start = dayDate(day).timeIntervalSince1970
                    let worked = { (t: SnapTask) in t.lastActivity >= start && t.lastActivity < start + 86400 }
                    group("Done that day", Palette.done, snap.tasks.filter(snap.isDone), snap)
                    group("Progressed", Palette.active,
                          snap.tasks.filter { !snap.isDone($0) && $0.section != "onHold" && worked($0) }, snap)
                    group("Still open", Palette.idle,
                          snap.tasks.filter { !snap.isDone($0) && $0.section != "onHold" && !worked($0) }, snap)
                    group("On hold", Palette.onHold, snap.tasks.filter { !snap.isDone($0) && $0.section == "onHold" }, snap)
                    Text("Snapshot as of \(Date(timeIntervalSince1970: snap.updatedAt).formatted(date: .omitted, time: .shortened)). Since then only your own edits change it.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).padding(16)
                }
            }
            .padding(.bottom, 8)
            .overlayScrollers()
        }
    }

    @ViewBuilder private func group(_ title: String, _ tint: Color, _ items: [SnapTask], _ snap: DaySnapshot) -> some View {
        if !items.isEmpty {
            Section {
                Card(items: items) { SnapRow(t: $0, day: day, snap: snap, store: store) }
            } header: {
                SectionHeader(title: title, count: items.count, tint: tint, collapsible: false, open: true, toggle: {})
            }
        }
    }
}

// Settings: which outside tools are set up, the optional session-naming rule, and text sizes
// (one row per kind of text, each with − / + and a sample drawn at the chosen size).
struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject private var sizes = TextSizes.shared
    @State private var ruleInstalled = NamingRule.installed
    @State private var showRule = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading("Integrations")
                if store.integrations.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
                } else {
                    Card(items: store.integrations) { integrationRow($0) }
                }
                Text("Settings of your own, like tool paths or your GitHub org, go in config.json in the app's data folder.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.top, 6)

                heading("Session naming")
                namingCard

                heading("Text size")
                Card(items: TextRole.allCases) { role in row(role) }
                Button("Reset to defaults") { sizes.reset() }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                    .disabled(sizes.isDefault)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .padding(.bottom, 8)
            .overlayScrollers()
        }
        .onAppear { store.checkIntegrations(); ruleInstalled = NamingRule.installed }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private func integrationRow(_ i: Integration) -> some View {
        let color: Color = switch i.state {
        case .ready: Palette.done
        case .signedOut: Palette.needsYou
        case .missing: Palette.idle
        }
        return HStack(alignment: .top, spacing: 9) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(i.name).font(.system(size: 12, weight: .semibold))
                    Text(i.detail).font(.system(size: 11)).foregroundStyle(color)
                }
                Text(i.purpose).font(.system(size: 10.5)).foregroundStyle(.secondary)
                if let fix = i.fix {
                    Text(fix).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // The rule lives in the user's own ~/.claude/CLAUDE.md, added or removed only from here.
    private var namingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Have Claude name a session reviewing a teammate's PR \"Team code review: …\", so it's recognised at once. Without it, review sessions are still found, by the PR's author.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if ruleInstalled {
                    Label("Added to ~/.claude/CLAUDE.md", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.done)
                    Spacer()
                    Button("Remove") { NamingRule.remove(); ruleInstalled = NamingRule.installed }
                } else {
                    Button("Add to ~/.claude/CLAUDE.md") { NamingRule.install(); ruleInstalled = NamingRule.installed }
                        .foregroundStyle(Palette.claude)
                    Spacer()
                }
                Button(showRule ? "Hide rule" : "Show rule") { withAnimation(Motion.change) { showRule.toggle() } }
            }
            .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
            if showRule {
                Text(NamingRule.text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
        .padding(.horizontal, 10)
    }

    private func row(_ role: TextRole) -> some View {
        let size = sizes.size(role)
        let style: AnyShapeStyle = switch role {
        case .count: AnyShapeStyle(Palette.active)
        case .meta: AnyShapeStyle(.tertiary)
        case .detail: AnyShapeStyle(.secondary)
        default: AnyShapeStyle(.primary)
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.label).font(.system(size: 12, weight: .semibold))
                    Text(role.hint).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                IconButton(symbol: "minus", help: "Smaller", tint: Palette.claude) { sizes.step(role, by: -0.5) }
                    .disabled(size <= role.base + TextSizes.range.lowerBound)
                Text(String(format: "%g", size))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(size == role.base ? .secondary : .primary)
                    .frame(width: 30)
                IconButton(symbol: "plus", help: "Larger", tint: Palette.claude) { sizes.step(role, by: 0.5) }
                    .disabled(size >= role.base + TextSizes.range.upperBound)
            }
            Text(role.sample)
                .font(.system(size: size, weight: [.title, .header, .count].contains(role) ? .bold : .regular))
                .foregroundStyle(style)
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

// One section of today's list: what it holds and how it shows.
struct SectionSpec {
    let title: String
    let short: String  // its label in the count strip
    let tint: Color
    let items: [Session]
    var collapsible = false
    var startOpen = false
    var trailing: (label: String, action: () -> Void)? = nil
}

struct ContentView: View {
    @ObservedObject private var sizes = TextSizes.shared
    @ObservedObject var store: Store
    @State private var toggled: Set<String> = []  // collapsible sections flipped from their default
    @State private var viewDay: String?  // nil: today, live
    @State private var jumpTo: String?   // a section the count strip asked to scroll to
    @State private var showSettings = false

    private var specs: [SectionSpec] {
        [
            SectionSpec(title: "Needs you", short: "Needs you", tint: Palette.needsYou, items: store.needsYou),
            SectionSpec(title: "In progress", short: "In progress", tint: Palette.active, items: store.active),
            SectionSpec(title: "Idle lately", short: "Idle", tint: Palette.idle, items: store.idle,
                        collapsible: true, startOpen: true,
                        trailing: ("Mark all done", { store.markAllDone(store.idle) })),
            SectionSpec(title: "On hold", short: "On hold", tint: Palette.onHold, items: store.onHold, collapsible: true),
            SectionSpec(title: "Scheduled", short: "Scheduled", tint: Palette.scheduled,
                        items: store.scheduled.filter { !$0.waiting }, collapsible: true),
            SectionSpec(title: "Done today", short: "Done", tint: Palette.done, items: store.doneToday,
                        collapsible: true, startOpen: true),
        ]
    }

    private func isOpen(_ spec: SectionSpec) -> Bool {
        !spec.collapsible || spec.startOpen != toggled.contains(spec.title)
    }

    // Opens a section if it is collapsed, then scrolls to it.
    private func reveal(_ title: String) {
        guard let spec = specs.first(where: { $0.title == title }) else { return }
        if !isOpen(spec) { toggled.formSymmetricDifference([spec.title]) }
        jumpTo = spec.title
    }

    // Every section's count at a glance; tapping one opens that section and scrolls to it.
    private var countStrip: some View {
        HStack(spacing: 0) {
            ForEach(specs, id: \.title) { spec in
                Button { reveal(spec.title) } label: {
                    VStack(spacing: 1) {
                        Text("\(spec.items.count)")
                            .font(.system(size: sizes.pt(.count), weight: .bold)).monospacedDigit()
                            .contentTransition(.numericText())  // digits roll when a count changes
                            .foregroundStyle(spec.items.isEmpty ? Color.secondary.opacity(0.45) : spec.tint)
                        Text(spec.short)
                            .font(.system(size: sizes.pt(.count, -7), weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(spec.items.isEmpty)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 6)
    }

    private var today: String { dayKey(Date()) }
    private var prevDay: String? { store.days.last { $0 < (viewDay ?? today) } }
    private var nextDay: String? {
        guard let v = viewDay, let n = store.days.first(where: { $0 > v }), n < today else { return nil }
        return n
    }

    var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)  // lets the button's hover hint overlap the list below
            if showSettings {
                Divider()
                SettingsView(store: store).canvas()
            } else {
                if viewDay == nil, let err = store.judge?.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
                }
                if viewDay == nil, let note = store.triageNote {
                    Label(note, systemImage: "checkmark.circle")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 14).padding(.bottom, 6)
                        .transition(.opacity)
                }
                if viewDay == nil { countStrip }
                Divider()
                Group {
                    if let day = viewDay {
                        DayView(day: day, store: store)
                    } else {
                        live
                    }
                }
                .canvas()
                footer
            }
        }
        .frame(minWidth: 300, minHeight: 260)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(RenderCheck.shared.$settings.dropFirst()) { showSettings = $0 }
    }

    private var header: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: "Previous day") { viewDay = prevDay }
                .disabled(prevDay == nil)
            VStack(alignment: .leading, spacing: 0) {
                Text(dayDate(viewDay ?? today).formatted(
                    Date.FormatStyle(locale: english).weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 14, weight: .bold))
                Text(viewDay == nil ? "Today" : "History")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            IconButton(symbol: "chevron.right", help: "Next day") { viewDay = nextDay }
                .disabled(viewDay == nil)
            Spacer()
            if showSettings {
                Button("Done") { showSettings = false }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.claude)
            } else {
            IconButton(symbol: "textformat.size", help: "Text size") { showSettings = true }
            if viewDay != nil {
                Button("Back to today") { viewDay = nil }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
            } else {
                TriageButton(running: store.judging) { store.runJudge() }
                    .hoverHint(judgeHelp)
                    .contextMenu {
                        Button("Triage All Again") { store.runJudge(all: true) }
                            .disabled(store.judging)
                        Button("View Last Run's Steps") { NSWorkspace.shared.open(judgeTraceMDURL) }
                            .disabled(!FileManager.default.fileExists(atPath: judgeTraceMDURL.path))
                    }
            }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    private var live: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // A plain stack, all rows laid out: a lazy one only guessed the height of sections it
            // hadn't drawn, so jumps landed short and kept correcting themselves (the flicker).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(specs, id: \.title) { section($0) }
                if store.needsYou.isEmpty && store.active.isEmpty && store.idle.isEmpty {
                    Text("Nothing open right now")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
            .padding(.bottom, 8)
            .overlayScrollers()
        }
        // Scroll once the section has had a moment to expand.
        .onChange(of: jumpTo) { target in
            guard let target else { return }
            jumpTo = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("anchor:" + target, anchor: .top) }
            }
        }
        .onReceive(RenderCheck.shared.$jump.compactMap { $0 }) { title in
            RenderCheck.shared.jump = nil
            reveal(title)
        }
        }
    }

    // One line of Claude usage; the icon opens the last triage's steps.
    @ViewBuilder private var footer: some View {
        if viewDay == nil && !store.runs.isEmpty {
            Divider()
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Palette.claude)
                Text(usageLine).font(.system(size: sizes.pt(.meta))).foregroundStyle(.secondary)
                Spacer()
                if FileManager.default.fileExists(atPath: judgeTraceMDURL.path) {
                    IconButton(symbol: "doc.text.magnifyingglass", help: "View the last triage's steps") {
                        NSWorkspace.shared.open(judgeTraceMDURL)
                    }
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 3)
        }
    }

    private var usageLine: String {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let today = store.runs.filter { $0.at >= start }
        let tokens = today.reduce(0) { $0 + $1.tokensIn + $1.tokensOut }
        return "\(today.count) Claude run\(today.count == 1 ? "" : "s") today · \(tokens / 1000)k tokens"
    }

    // What Triage does and what it costs, in one hint: runs come out of the Claude plan.
    private var judgeHelp: String {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let today = store.runs.filter { $0.at >= start }.count
        let recent = store.runs.filter { $0.kind == nil && $0.ok }.suffix(5)
        var usage = "Uses your Claude plan: \(today) run\(today == 1 ? "" : "s") today"
        if !recent.isEmpty {
            usage += ", about \(recent.map { $0.tokensIn + $0.tokensOut }.reduce(0, +) / recent.count / 1000)k tokens each"
        }
        let last = store.judge.map { "Last run " + relative(Date(timeIntervalSince1970: $0.generatedAt)) + ". " } ?? ""
        return "Gives each task in Needs you and In progress a one-line verdict. "
            + "Only tasks that changed since their last verdict are sent; unchanged ones are rechecked daily.\n"
            + "\(usage).\n\(last)Right-click to triage all again, or for the steps."
    }

    @ViewBuilder private func section(_ spec: SectionSpec) -> some View {
        if !spec.items.isEmpty {
            let open = isOpen(spec)
            Section {
                if open {
                    let entries = spec.items.flatMap { s in
                        [Entry(session: s, nested: false)] + store.children(of: s).map { Entry(session: $0, nested: true) }
                    }
                    Card(items: entries) { e in
                        Row(s: e.session, store: store, nested: e.nested)
                    }
                    .transition(.opacity)  // a section's card fades in when its first task arrives
                }
            } header: {
                SectionHeader(title: spec.title, count: spec.items.count, tint: spec.tint,
                              collapsible: spec.collapsible, open: open, trailing: spec.trailing) {
                    withAnimation(Motion.change) { toggled.formSymmetricDifference([spec.title]) }
                }
                .id("anchor:" + spec.title)  // the count strip scrolls here
                .transition(.opacity)
            }
        }
    }
}

func log(_ line: String) {
    let url = dataDir.appendingPathComponent("log.txt")
    let entry = "\(Date()) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(entry.data(using: .utf8)!); try? h.close()
    } else {
        try? entry.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var renderTimer: Timer?

    @objc func showPanel() { panel.orderFrontRegardless() }
    @objc func quit() { NSApp.terminate(nil) }

    // Closing the panel (close button or Esc) only hides it; the menu bar icon brings it back.
    func windowWillClose(_ notification: Notification) {
        log("panel closed (event: \(NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "none"))")
    }

    func applicationWillTerminate(_ notification: Notification) { log("terminate") }

    // Opening the app again (Finder, Spotlight, `open`) brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // A `render-now` file in the data folder saves the panel as render.png, for checking the
    // look without screen-recording permission. A number in the file renders at that height;
    // the word "actions" shows every row's hover buttons, and "settings" the text-size page.
    @objc func renderIfAsked() {
        // A `jump-now` file holding a section title acts like clicking that section's count.
        let jump = dataDir.appendingPathComponent("jump-now")
        if let title = try? String(contentsOf: jump, encoding: .utf8) {
            try? FileManager.default.removeItem(at: jump)
            RenderCheck.shared.jump = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trigger = dataDir.appendingPathComponent("render-now")
        guard let request = try? String(contentsOf: trigger, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: trigger)
        let saved = panel.frame
        let words = request.split(whereSeparator: \.isWhitespace)
        if let h = words.compactMap({ Double($0) }).first {
            panel.setFrame(NSRect(x: saved.minX, y: saved.maxY - h, width: saved.width, height: h), display: true)
        }
        RenderCheck.shared.showActions = words.contains("actions")
        if words.contains("settings") { RenderCheck.shared.settings = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let v = self.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dataDir.appendingPathComponent("render.png"))
            }
            RenderCheck.shared.showActions = false
            if words.contains("settings") { RenderCheck.shared.settings = false }
            self.panel.setFrame(saved, display: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyData()  // before anything creates the new data folder
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Claude Tasks")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Panel", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Claude Tasks"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ContentView(store: Store()))
        if !panel.setFrameUsingName("ClaudeTasksPanel"), let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 620))
        }
        panel.setFrameAutosaveName("ClaudeTasksPanel")
        panel.orderFrontRegardless()
        renderTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(renderIfAsked),
                                           userInfo: nil, repeats: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
