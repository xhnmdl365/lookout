// Day snapshots and their summaries.
import SwiftUI
import AppKit

extension Store {
    // MARK: Day snapshots

    private func snapshotURL(_ day: String) -> URL { daysDir.appendingPathComponent("\(day).json") }

    func loadSnapshot(_ day: String) -> DaySnapshot? {
        (try? Data(contentsOf: snapshotURL(day))).flatMap { try? JSONDecoder().decode(DaySnapshot.self, from: $0) }
    }

    // `notify` redraws views showing the day; today's own snapshot, rewritten as the live list
    // moves, has none on screen, so writing it doesn't redraw the list.
    private func saveSnapshot(_ snap: DaySnapshot, notify: Bool = true) {
        try? JSONEncoder().encode(snap).write(to: snapshotURL(snap.day))
        refreshDays()
        if notify { objectWillChange.send() }
    }

    func refreshDays() {
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: daysDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        if found != days { days = found }
    }

    // Only today's file is ever rewritten from live data, so past days stay as they were.
    func writeTodaySnapshot() {
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
        saveSnapshot(file, notify: false)
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
    func autoSummarize() {
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
}
