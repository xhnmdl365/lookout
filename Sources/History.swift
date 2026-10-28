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
            let review = teamReviews.contains(s.id)
            return SnapTask(id: s.id, title: s.title, project: s.project, section: section, detail: s.detail,
                            needs: s.nextStep, doneReason: section == "done" ? mark(s)?.reason : nil,
                            lastActivity: s.lastActivity.timeIntervalSince1970, deleted: s.deleted,
                            review: s.isTodo ? nil : review,  // said either way, so the summary never has to guess
                            ticket: review ? nil : ticketStatus(s) ?? ticket(for: s),
                            reviewPRs: review ? reviewedTeamPRs(s).map(prLabel) : nil,
                            todo: s.isTodo ? true : nil)
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

    // Puts a task marked done after the fact into that day's record: as a correction when the day
    // already lists it, else as one of that day's finished tasks.
    func recordDone(_ s: Session, on day: String) {
        guard var snap = loadSnapshot(day) else { return }
        if let t = snap.tasks.first(where: { $0.id == s.id }) { return setDone(day, t, true) }
        snap.tasks.append(SnapTask(id: s.id, title: s.title, project: s.project, section: "done", detail: s.detail,
                                   needs: nil, doneReason: reasonManual,
                                   lastActivity: s.lastActivity.timeIntervalSince1970, deleted: false,
                                   todo: s.isTodo ? true : nil))
        saveSnapshot(snap)
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
        // Only what was worked in that day. A task marked done then without being touched (an
        // idle one cleared away, archived, closed by a rule) did no work worth reporting; but a
        // to-do has nothing to touch, so doing it is the work, and one done that day counts.
        // Done ones first, then the most recently worked in.
        let start = dayDate(day).timeIntervalSince1970, end = start + 86400
        let moved = snap.tasks.filter { (start..<end).contains($0.lastActivity) || ($0.todo == true && snap.isDone($0)) }
            .sorted { (snap.isDone($0) ? 1 : 0, $0.lastActivity) > (snap.isDone($1) ? 1 : 0, $1.lastActivity) }
        guard !moved.isEmpty, let claude = Tools.claude else { return }
        // Each task's transcript, for what it did that day; read off the main thread below.
        let transcripts = Dictionary(sessions.compactMap { s in s.cliId.map { (s.id, transcriptURL(cwd: s.runCwd, cliId: $0)) } },
                                     uniquingKeysWith: { a, _ in a })
        // Each task's PRs, with what gh last said of them if it has been asked. The Claude app links
        // a folder's PR to every session there, so these are only candidates.
        let candidatePRs: [String: [(url: String, known: PRInfo?)]] =
            Dictionary(sessions.map { s in
                (s.id, Array(Set(s.prs.map(\.url) + (textRefs[s.id] ?? []))).map { ($0, prLive[$0]) })
            }, uniquingKeysWith: { a, _ in a })
        let gh = Tools.gh
        summarizing = day
        let started = Date().timeIntervalSince1970
        DispatchQueue.global(qos: .utility).async {
            // A finished or deleted session with nothing said or asked that day was only closed
            // then (deleting or archiving one stamps it with that time), so it isn't reported.
            let rows: [[String: Any]] = moved.compactMap { t in
                var r: [String: Any] = ["title": t.title, "section": t.section, "done": snap.isDone(t),
                                        "detail": t.detail ?? "", "needs": t.needs ?? "", "closedBy": t.doneReason ?? ""]
                if t.todo == true { r["kind"] = "to-do" } else if let review = t.review { r["kind"] = review ? "review" : "own work" }
                if let ticket = t.ticket { r["ticket"] = ticket }
                if let prs = t.reviewPRs, !prs.isEmpty { r["prs"] = prs }
                var said = [t.title, t.detail ?? "", t.needs ?? ""]
                if let url = transcripts[t.id] {
                    let trail = dayTrail(url, from: Date(timeIntervalSince1970: start), to: Date(timeIntervalSince1970: end))
                    if !trail.recaps.isEmpty { r["turns"] = trail.recaps }
                    else if !trail.prompts.isEmpty { r["asked"] = trail.prompts }
                    said += trail.recaps + trail.prompts
                }
                // Its own PRs: the candidates it mentioned that day, as they stood at the day's end.
                // Finished tasks' PRs aren't watched, so gh is asked about those here.
                let text = said.joined(separator: "\n")
                let states = (candidatePRs[t.id] ?? []).filter { pr in
                    guard let n = pr.url.split(separator: "/").last else { return false }
                    return text.range(of: #"(#|/pull/)"# + n + #"(?!\d)"#, options: .regularExpression) != nil
                }.prefix(5).compactMap { pr -> String? in
                    guard let info = pr.known ?? gh.flatMap({ prInfo(gh: $0, url: pr.url) }), info.state != "UNKNOWN" else { return nil }
                    return "\(prLabel(pr.url)) " + ((info.endedAt ?? 0) >= end ? "OPEN" : info.state)
                }
                if !states.isEmpty { r["prStates"] = Array(states) }
                let worked = r["turns"] != nil || r["asked"] != nil
                if t.todo != true, !worked, snap.isDone(t) || t.deleted { return nil }
                return r
            }
            let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: summaryInputURL)  // a copy, for checking what the summary was given
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let prompt = """
            Below (JSON) are the user's Claude Code tasks that moved on \(day), finished ones first. \
            `done` already includes the user's own corrections; trust it. `section`: needsYou = waiting \
            on the user, active = in progress, onHold = parked, todo = an open to-do. `kind` "to-do" is \
            something the user added by hand; it has no session, just a title and maybe a note, and \
            is ✅ when done, else ⏳; write it like their own tasks. `kind` "review" means the user reviewed \
            a teammate's PR, named in `prs`; when `kind` is missing, a title starting "Code review" or \
            "Team code review" is a review. `ticket` is the Jira key and its status. `prStates` are the \
            PRs the task touched and their state as GitHub reported it that day (OPEN, MERGED, CLOSED); \
            use them for where it stands, e.g. "PR #39 merged". Only PRs it mentioned that day are \
            listed, each as it stood at the end of that day.
            What happened that day: `turns` are the recaps Claude wrote at the end of each turn, oldest \
            first (the first two and the last ten when there were more); a terminal session has none, \
            and `asked` holds what the user typed instead. `detail` and `needs` are its latest status. \
            `closedBy` says how a finished task was closed; it decides the ✅, it is not the work.

            Write the user a summary of that day for their own reference, in English, one line per item, \
            no heading, no bullets:
            - Each of the user's own tasks, in the order given: an emoji, the ticket key when there is \
            one, a short name in English (translate a title in another language), a colon, then one or \
            two plain sentences, at most 35 words, on what was \
            actually done that day and where it stands, drawn from `turns` or `asked`: what was found, \
            built, fixed, sent or decided. Never write how a task was closed ("marked done", \
            "archived", "accepted the suggestion"); when there's nothing to go on, say what the task \
            was about. Emoji: ✅ finished that day; ⛔ blocked or waiting on someone, the user \
            included; ⏳ still in progress.
            - All the reviews together on one line: "👀 Reviewed: " and the PRs (or the task names when \
            no PR is given), comma-separated. Say nothing about how the reviews went.
            - Last, one line: "Next: " and what to do first, in a few words.
            Use only what the data says; do not invent anything. Example lines:
            ✅ PROJ-12 Export dialog: found the progress bar stalled on large files; fixed it, merged, and confirmed on staging.
            ⛔ PROJ-34 Login retry: PR ready with tests passing, waiting on the team lead's approval.
            👀 Reviewed: api#82, web#17

            \(json)
            """
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
