// The task list: loading sessions, marks, and the sections they fall into.
import SwiftUI
import AppKit

final class Store: ObservableObject {
    @Published var sessions: [Session] = [] {
        didSet {
            byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            derived = nil
        }
    }
    private var byId: [String: Session] = [:]
    @Published var manual = Manual() { didSet { derived = nil } }
    // What every row asks about the list as a whole (open tasks, children, sections), worked out
    // once per change instead of once per row. Cleared when sessions or marks change, and each minute.
    private var derived: Derived?
    private struct Derived {
        var open: [Session]
        var children: [String: [Session]]
        var shares: [Source: Double]  // each source's part of the open sessions
        var sections: [String: [Session]] = [:]
        var search: [String: String] = [:]  // what search matches each task on
    }
    private var lastTick = Date()
    @Published var judge: JudgeFile?
    @Published var judging = false
    @Published var triageNote: String?  // a short-lived word on the last Triage click
    @Published var integrations: [Integration] = []
    @Published var runs: [JudgeRun] = []
    @Published var days: [String] = []        // snapshot days, oldest first
    @Published var summarizing: String?       // the day Claude is summarizing
    @Published var todos: [Todo] = []         // the user's own to-dos, kept in todos.json
    @Published var addingTodo = false         // the new to-do form is open
    // Triage is opt-in: each run is a `claude -p` call that counts toward the user's plan. Off,
    // its button, verdicts and suggestions are gone, and earlier verdicts close nothing.
    @Published var triageEnabled = UserDefaults.standard.bool(forKey: "triageEnabled") {
        didSet {
            UserDefaults.standard.set(triageEnabled, forKey: "triageEnabled")
            reload()
        }
    }
    // How many days a task stays in Active after it last moved, set in Settings.
    static let activeDayRange = 1...30
    @Published var activeDays = (UserDefaults.standard.object(forKey: "activeDays") as? Int) ?? 7 {
        didSet {
            UserDefaults.standard.set(activeDays, forKey: "activeDays")
            derived = nil  // the sections are worked out again
        }
    }
    var lastSnapshotTasks: Data?
    var summaryTried: [String: Date] = [:]  // day -> last auto attempt, retried after 30 min
    var prLive: [String: PRInfo] = [:]  // PR url -> from gh
    var repoByCwd: [String: String?] = [:]  // folder -> its GitHub "owner/repo", nil when not GitHub
    var me: String?                         // the GitHub login, to tell own PRs from teammates'
    var textRefs: [String: [String]] = [:]  // task id -> PRs it names, its own and in its text
    var teamReviews = Set<String>()    // tasks reviewing a teammate's PR
    var tickets: [String: (status: String, done: Bool, changedAt: Double?)] = [:]  // Jira key -> from acli
    var ticketMissing: [String: Double] = [:]  // keys Jira says it doesn't have -> when; asked again daily
    var jiraSite = config.jiraSite     // for ticket links; else found from acli
    private var lastPrRefresh = Date.distantPast
    private var timer: Timer?
    private let loadQueue = DispatchQueue(label: "taskfloat.load", qos: .utility)
    // Transcript path -> what it held at that mtime. Touched only on loadQueue.
    private var transcriptCache: [String: (mtime: Double, terminal: Bool, session: Session?)] = [:]
    // Desktop session file path -> what it held at that mtime. Touched only on loadQueue.
    private var sessionCache: [String: (mtime: Double, session: Session)] = [:]
    // Transcript path -> the question it left open, and what it says about the work, at that
    // mtime. Touched only on loadQueue.
    private var askCache: [String: (mtime: Double, tail: TranscriptTail, facts: TranscriptFacts)] = [:]
    // Whether a load has finished; the first one skips reading whole transcripts, so the list
    // shows at once and the next pass fills in. Touched only on loadQueue.
    private var loadedOnce = false

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
        if let data = try? Data(contentsOf: todosURL) { todos = (try? JSONDecoder().decode([Todo].self, from: data)) ?? [] }
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
            let files = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles])  // saves in progress use hidden temp files
            // Cowork tasks' records sit in a folder of their own, and read the same way.
            for url in (files?.allObjects.compactMap { $0 as? URL } ?? []) + coworkRecords() {
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
                    out.append(autoreleasepool { self.withPendingAsk(cached.session) })
                    continue
                }
                guard let data = try? Data(contentsOf: url),
                      let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    // Caught mid-write: keep what it held last time. Dropping it would make it
                    // look deleted, and get it marked done.
                    if let cached = self.sessionCache[url.path] { out.append(autoreleasepool { self.withPendingAsk(cached.session) }) }
                    continue
                }
                let summary = d["postTurnSummary"] as? [String: Any]
                let prs = (d["prs"] as? [[String: Any]] ?? []).compactMap { p -> PR? in
                    guard let u = p["url"] as? String else { return nil }
                    return PR(url: u, number: p["prNumber"] as? Int ?? 0, state: p["state"] as? String ?? "",
                              notOwn: p["notOwnRead"] as? Bool ?? false)
                }
                let runCwd = native(d["cwd"] as? String ?? "")
                let cowork = url.path.hasPrefix(coworkRoot.path)
                let localId = url.deletingPathExtension().lastPathComponent
                let cliId = (d["cliSessionId"] as? String).map(native)
                var session = Session(
                    id: native(cowork ? "cowork_" + localId.dropFirst("local_".count) : localId),
                    cliId: cliId,
                    title: d["title"] as? String ?? "(untitled)",
                    // originCwd is the repo a worktree session was started from; a Cowork task
                    // runs in a folder of its own, but works on the first folder the user chose.
                    cwd: (d["originCwd"] as? String).map(native)
                        ?? (cowork ? (d["userSelectedFolders"] as? [String])?.first.map(native) : nil) ?? runCwd,
                    runCwd: runCwd,
                    lastActivity: Date(timeIntervalSince1970: ((d["lastActivityAt"] as? Double) ?? 0) / 1000),
                    status: summary?["status_category"] as? String,
                    detail: summary?["status_detail"] as? String,
                    needs: summary?["needs_action"] as? String,
                    scheduledTaskId: d["scheduledTaskId"] as? String,
                    prs: prs,
                    archived: (d["isArchived"] as? Bool) == true,
                    deleted: false,
                    parentId: ((d["spawnedFrom"] as? [String: Any])?["sessionId"] as? String).map(native),
                    startedAt: (d["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
                if cowork { session.coworkTranscript = cliId.flatMap { coworkTranscriptURL(record: url, cliId: $0) } }
                // A turn is open while the user's latest message is newer than the last turn's end.
                if !session.archived, let asked = d["latestUserFrameAt"] as? Double, let edge = d["lastTurnEdgeAt"] as? Double {
                    session.turnOpen = asked > edge
                    // What made it look open, to check a task wrongly shown as Working.
                    if session.turnOpen, self.sessionCache[url.path]?.session.turnOpen != true {
                        log("turn open: \(session.id) asked \(Int(asked)) edge \(Int(edge)) status \(summary?["status_category"] as? String ?? "none")")
                    }
                }
                self.sessionCache[url.path] = (mtime, session)
                out.append(autoreleasepool { self.withPendingAsk(session) })
            }
            out.sort { $0.lastActivity > $1.lastActivity }
            // One row per session: a save caught halfway can leave a second copy of its file for a
            // moment, which would show the task twice. The newest copy stays.
            var seen = Set<String>()
            out = out.filter { seen.insert($0.id).inserted }
            // Keep only the newest unarchived run of each scheduled task.
            var seenTasks = Set<String>()
            out = out.filter { s in
                guard let t = s.scheduledTaskId else { return true }
                return !s.archived && seenTasks.insert(t).inserted
            }
            self.loadedOnce = true
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
        // Once a minute the list redraws even when nothing changed, so "5 min. ago" and the
        // sections that go by age keep up.
        if Date().timeIntervalSince(lastTick) >= 60 {
            lastTick = Date()
            derived = nil
            objectWillChange.send()
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
            DispatchQueue.main.async {
                self.integrations = found
                if config.jiraSite == nil, let site = found.first(where: { $0.id == "jira" })?.site { self.jiraSite = site }
            }
        }
    }

    // Adds the question a desktop session's last turn left open, whether the user stopped that
    // turn, and its branch and reviewed PRs (for a Cowork task, also whether a turn is open and
    // its last prompt),
    // read again only when its transcript changes. Archived and scheduled sessions are skipped:
    // nobody's waiting there.
    private func withPendingAsk(_ s: Session) -> Session {
        guard !s.archived, s.scheduledTaskId == nil, let url = s.transcript else { return s }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let tail: TranscriptTail, facts: TranscriptFacts
        if let cached = askCache[url.path], cached.mtime == mtime {
            (tail, facts) = (cached.tail, cached.facts)
        } else if !loadedOnce && askCache[url.path] == nil {
            (tail, facts) = (readTail(of: url), TranscriptFacts())  // not cached: read in full next pass
        } else {
            tail = readTail(of: url)
            facts = scanTranscript(url, from: askCache[url.path]?.facts ?? TranscriptFacts())
            askCache[url.path] = (mtime, tail, facts)
        }
        var s = s
        s.pendingAsk = tail.ask
        if s.source == .cowork {
            s.turnOpen = tail.open
            s.detail = tail.lastPrompt.map { "Last prompt: " + clip($0) }
        }
        if tail.interrupted { s.turnOpen = false }  // stopped: the record still shows the turn open
        s.gitBranch = facts.branch
        s.workBranches = facts.branches
        s.reviewRefs = facts.reviewRefs
        s.diffRefs = facts.diffRefs
        s.pushed = facts.pushed
        s.lastWrite = mtime > 0 ? Date(timeIntervalSince1970: mtime) : nil
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
                    guard let e = autoreleasepool(invoking: { transcriptEntrypoint(url) }) else { continue }  // still empty; look again later
                    terminal = e == "cli"
                }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                let s = terminal == true ? autoreleasepool { parseTerminalSession(url, mtime: mtime, created: created) } : nil
                transcriptCache[url.path] = (mtime, terminal ?? false, s)
                if let s { found.append(s) }
            }
        }
        return found
    }

    // MARK: Opening a task

    // Desktop sessions open in the app, Cowork tasks in its Cowork view; terminal ones switch to their Terminal tab when one
    // is running, else resume in an idle tab in their folder, or a new tab. Never starts a second
    // copy of a running session.
    func open(_ id: String) {
        guard !id.hasPrefix("todo_") else { return }  // a to-do has no session to open
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
                        // A tab already open in the session's folder and idle at its prompt is
                        // reused, so each resume doesn't leave another tab behind.
                        let idle = idleTerminalTTYs()
                        DispatchQueue.global(qos: .userInitiated).async {
                            let tty = ttyInFolder(idle, cwd: s.runCwd)
                            DispatchQueue.main.async { resumeInTerminal(cwd: s.runCwd, uuid: uuid, tty: tty) }
                        }
                    }
                }
            }
            return
        }
        if id.hasPrefix("cowork_") {
            NSWorkspace.shared.open(URL(string: "claude://claude.ai/cowork/local_\(id.dropFirst("cowork_".count))")!)
            return
        }
        NSWorkspace.shared.open(URL(string: "claude://code/continue?session=\(id)")!)
    }

    // Layer 1 rules, plus layer 2 verdicts from the last Claude run.
    private func apply(_ loaded: [Session], deletedAt: [String: Double]) {
        var all = loaded + todos.map(todoSession)
        var known = manual.known ?? [:]
        var marks = manual.marks ?? [:]
        let dismissed = manual.dismissed ?? []
        let now = Date().timeIntervalSince1970
        let ids = Set(loaded.map(\.id))

        for s in loaded where !s.archived && s.scheduledTaskId == nil && !s.isTodo {
            known[s.id] = Known(title: s.title, cwd: s.cwd)
        }
        // Tracked sessions whose file is gone were deleted.
        for (id, k) in known where !ids.contains(id) {
            // When the app left no deletion time, the time it was first found gone, kept in its
            // mark; "now" on every pass would make it look changed on every refresh.
            let ms = deletedAt[String(id.dropFirst("local_".count))] ?? 0
            let at = ms > 0 ? ms / 1000 : marks[id]?.at ?? now
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
        if triageEnabled, let j = judge {
            let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for v in j.verdicts where v.verdict == "done" && marks[v.id] == nil && !dismissed.contains(v.id) {
                // Only if nothing happened since Claude looked; a failed check leaves it a suggestion.
                if let s = byId[v.id], v.current(for: s, runAt: j.generatedAt), v.holds(lastActivity: s.lastActivity) {
                    marks[v.id] = Mark(at: now, reason: "Claude: " + v.reason, auto: true)
                }
            }
        }

        // Changes found by a refresh (a merged PR, a ticket gone Done, a new task) ease in too.
        // Unchanged data is left alone, so a quiet refresh redraws nothing.
        withAnimation(Motion.refresh) {
            if (manual.known ?? [:]) != known || (manual.marks ?? [:]) != marks {
                manual.known = known
                manual.marks = marks
                save()
            }
            let next = all.filter { !$0.archived || known[$0.id] != nil }
            if next != sessions { sessions = next }
        }
        writeTodaySnapshot()
        autoSummarize()
    }

    // MARK: Marks

    func mark(_ s: Session) -> Mark? { manual.marks?[s.id] }

    // Done unless the session saw activity after it was marked (work resumed).
    func isDone(_ s: Session) -> Bool {
        guard let m = mark(s) else { return false }
        return s.deleted || s.archived || s.lastActivity.timeIntervalSince1970 <= m.at + 60
    }

    func isPinned(_ s: Session) -> Bool { manual.pinned?.contains(s.id) ?? false }

    // Parked until the user unparks it, or works in the session again.
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

    // MARK: To-dos

    func todoSession(_ t: Todo) -> Session {
        Session(id: t.id, cliId: nil, title: t.title, cwd: "", runCwd: "",
                lastActivity: Date(timeIntervalSince1970: t.editedAt), status: nil,
                detail: t.note.flatMap { $0.isEmpty ? nil : $0 }, needs: nil, scheduledTaskId: nil, prs: [],
                archived: false, deleted: false, startedAt: Date(timeIntervalSince1970: t.createdAt))
    }

    func addTodo(title: String, note: String) {
        let now = Date().timeIntervalSince1970
        todos.append(Todo(id: "todo_" + UUID().uuidString.lowercased(), title: title, note: note.isEmpty ? nil : note,
                          createdAt: now, editedAt: now))
        addingTodo = false
        todosChanged()
    }

    func updateTodo(_ id: String, title: String, note: String) {
        guard let i = todos.firstIndex(where: { $0.id == id }),
              todos[i].title != title || (todos[i].note ?? "") != note else { return }
        todos[i].title = title
        todos[i].note = note.isEmpty ? nil : note
        todos[i].editedAt = Date().timeIntervalSince1970
        todosChanged()
    }

    func deleteTodo(_ id: String) {
        todos.removeAll { $0.id == id }
        manual.marks?[id] = nil
        manual.onHold?[id] = nil
        save()
        todosChanged()
    }

    // Saves the to-dos and puts them in the list at once, without waiting for the next refresh.
    private func todosChanged() {
        if let data = try? JSONEncoder().encode(todos) { try? data.write(to: todosURL) }
        withAnimation(Motion.change) { sessions = sessions.filter { !$0.isTodo } + todos.map(todoSession) }
    }

    // MARK: Done on an earlier day

    // The days a task left open from before today could be marked done on, newest first: from
    // yesterday back to the day it was last touched, at most a week.
    func earlierDoneDays(_ s: Session) -> [String] {
        let todayStart = Calendar.current.startOfDay(for: Date())
        guard s.lastActivity < todayStart, !isDone(s), !s.deleted, !s.archived else { return [] }
        return (1...7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: todayStart) }
            .filter { $0.addingTimeInterval(86400) > s.lastActivity }
            .map(dayKey)
    }

    // Marks a task done on an earlier day, for work finished then but not marked: it counts in
    // that day's record, not today's.
    func markDone(_ s: Session, on day: String) {
        let end = dayDate(day).timeIntervalSince1970 + 86400 - 60
        withAnimation(Motion.change) {
            manual.marks?[s.id] = Mark(at: min(end, Date().timeIntervalSince1970), reason: reasonManual, auto: false)
            save()
        }
        recordDone(s, on: day)
    }

    // MARK: Corrections

    // The user's say on what a task is: "review", "own", or nil to detect it.
    func kindOverride(_ s: Session) -> String? { manual.kindOverrides?[s.id] }

    func setKind(_ s: Session, _ kind: String?) {
        withAnimation(Motion.change) {
            var k = manual.kindOverrides ?? [:]
            k[s.id] = kind
            manual.kindOverrides = k
            save()
        }
        reload()
    }

    // The user's ticket for a task: a key, "" for none, or nil to detect it.
    func ticketOverride(_ s: Session) -> String? { manual.ticketOverrides?[s.id] }

    func setTicket(_ s: Session, _ key: String?) {
        var t = manual.ticketOverrides ?? [:]
        t[s.id] = key
        manual.ticketOverrides = t
        save()
        refreshPRs()  // reads the new ticket's status, then reloads
    }

    // MARK: Suggestions (layer 3)

    func suggestion(_ s: Session) -> String? {
        guard triageEnabled, let j = judge, !isDone(s), !isOnHold(s), !(manual.dismissed ?? []).contains("s:" + s.id),
              let v = j.verdicts.first(where: { $0.id == s.id && ["suggest_done", "done"].contains($0.verdict) }),
              v.current(for: s, runAt: j.generatedAt)
        else { return nil }
        // A done verdict that failed its check lands here too.
        return v.verdict == "done" ? v.reason + " (but you kept working after the merge)" : v.reason
    }

    // Triage's one-line verdict on a task it judged still active; gone once the session moves on.
    func verdictNote(_ s: Session) -> String? {
        guard triageEnabled, let j = judge, !isDone(s),
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

    // MARK: Sections

    private var cache: Derived {
        if let d = derived { return d }
        let open = sessions.filter { $0.scheduledTaskId == nil && !$0.archived && !$0.deleted && !isDone($0) }
        let d = Derived(open: open,
                        children: Dictionary(grouping: open.filter { $0.parentId != nil }, by: { $0.parentId! }),
                        shares: { let sessions = open.filter { !$0.isTodo }
                            return Dictionary(grouping: sessions, by: \.source).mapValues { Double($0.count) / Double(sessions.count) } }())
        derived = d
        return d
    }
    private var openTasks: [Session] { cache.open }
    private func recent(_ s: Session) -> Bool { s.age <= Double(activeDays) * 86400 || isPinned(s) }
    private func within(_ s: Session, days: Double) -> Bool { s.age <= days * 86400 }

    // The section a task belongs to on its own, or nil when it is done or scheduled.
    func baseSection(_ s: Session) -> String? {
        guard s.scheduledTaskId == nil, !s.archived, !s.deleted, !isDone(s) else { return nil }
        if isOnHold(s) { return "onHold" }
        if s.isTodo { return "todo" }  // stays until done: a to-do has no activity to go idle by
        if s.waiting && within(s, days: blockedDays) { return "needsYou" }
        if recent(s) { return "active" }
        return "idle"
    }

    // A session started from a listed parent shows under that parent instead of on its own.
    private func isNested(_ s: Session) -> Bool {
        guard let p = s.parentId, let parent = byId[p] else { return false }
        return baseSection(parent) != nil
    }

    func children(of s: Session) -> [Session] { cache.children[s.id] ?? [] }

    // What search matches a task on, worked out once per change like the sections.
    func searchText(_ s: Session) -> String {
        if let text = cache.search[s.id] { return text }
        let text = makeSearchText(s)
        derived?.search[s.id] = text
        return text
    }

    // A section's top-level tasks: pinned ones first, then newest first. A task with children sorts by its family's
    // newest activity, so a child's fresh progress lifts the whole family. And when a child is
    // waiting on the user, its whole family moves up to the waiting tasks that lead Active (from Active or Idle;
    // a family the user parked stays there).
    private func top(_ section: String) -> [Session] {
        if let done = cache.sections[section] { return done }
        let found = computeTop(section)
        derived?.sections[section] = found
        return found
    }

    private func computeTop(_ section: String) -> [Session] {
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
        let pin = { (s: Session) in self.isPinned(s) ? 1 : 0 }
        return sessions.filter { familySection($0) == section && !isNested($0) }
            .sorted { (pin($0), latest($0)) > (pin($1), latest($1)) }
    }

    var needsYou: [Session] { top("needsYou") + scheduled.filter(\.waiting) }
    var todoTasks: [Session] { top("todo") }
    var active: [Session] { top("active") }
    var idle: [Session] { top("idle") }
    var onHold: [Session] { top("onHold") }
    var scheduled: [Session] {
        sessions.filter { $0.scheduledTaskId != nil && !isDone($0) && within($0, days: scheduledDays) }
    }

    // What Triage looks at: Active, waiting tasks included, with their open children. Idle,
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

    // Whether a source's badge stays quiet (a grey icon) rather than in its colour. The source
    // most open tasks come from goes quiet, so the rarer ones stand out; when none has more than
    // two thirds of them, all keep their colours.
    func badgeIsQuiet(_ source: Source) -> Bool {
        (cache.shares[source] ?? 0) > 2.0 / 3
    }

    // The colour a task's dot takes, matching its section header.
    func tint(_ s: Session) -> Color {
        if s.deleted { return .gray.opacity(0.4) }
        if isDone(s) { return Palette.done }
        if isOnHold(s) { return Palette.onHold }
        if s.isTodo { return Palette.todo }
        if s.waiting { return Palette.needsYou }
        if s.scheduledTaskId != nil { return Palette.scheduled }
        return recent(s) ? Palette.active : Palette.idle
    }
}
