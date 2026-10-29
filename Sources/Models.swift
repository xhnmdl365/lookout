// Sessions, marks, verdicts and day snapshots, plus date formatting.
import SwiftUI
import AppKit

// Mark reasons the rules match on.
let reasonManual = "Manual"
let reasonArchived = "Archived"
let reasonDeleted = "Deleted"

struct PR: Hashable {
    let url: String
    let number: Int
    let state: String
}

// A PR as gh reported it.
struct PRInfo {
    var state: String
    var endedAt: Double? = nil      // when it was merged or closed
    var author: String? = nil
    var branch: String? = nil       // its head branch
    var title: String? = nil
    var reviewers = Set<String>()   // logins asked to review it, or who did
}

// A to-do the user added by hand: not a Claude session, so nothing tracks it; it's done when
// they say so. Shown as a Session with id "todo_<uuid>" so it shares the list's marks, holds
// and day records.
struct Todo: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var note: String?
    var createdAt: Double
    var editedAt: Double
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
    var gitBranch: String? = nil   // the folder's branch its transcript last recorded, terminal or desktop
    var workBranches: [String] = []  // branches the session itself checked out or pushed, oldest first
    var reviewRefs: [String] = []  // PRs it checked out or reviewed with gh: "#12" or "owner/repo#12"
    var diffRefs: [String] = []    // PRs it only diffed with gh
    var pushed = false             // it pushed a branch or opened a PR
    var turnOpen = false           // a turn has started and not ended: Claude is on it
    var lastWrite: Date? = nil     // when its transcript last changed

    // Waiting on the user: the app's own summary says blocked, or the last turn asked something.
    var waiting: Bool { status == "blocked" || pendingAsk != nil }
    var nextStep: String? { needs.flatMap { $0.isEmpty ? nil : $0 } ?? pendingAsk }

    // Claude is working on it right now. A turn left open by a crash or a forced quit would say
    // so forever, so it also needs something written in the last 15 minutes.
    var working: Bool {
        turnOpen && !waiting && Date().timeIntervalSince(max(lastActivity, lastWrite ?? .distantPast)) < 15 * 60
    }

    var age: TimeInterval { Date().timeIntervalSince(lastActivity) }

    // A `claude` run in a terminal rather than the desktop app; its id is "cli_<session uuid>".
    var isTerminal: Bool { id.hasPrefix("cli_") }

    // A to-do the user added by hand; its id is "todo_<uuid>".
    var isTodo: Bool { id.hasPrefix("todo_") }

    var project: String { projectName(cwd) }
}

// A string stored as Swift's own UTF-8. File names and JSONSerialization values arrive as
// bridged NSStrings, which make every dictionary lookup and comparison by them slow; ids and
// folders are looked up on every redraw.
func native(_ s: String) -> String {
    var s = s
    s.makeContiguousUTF8()
    return s
}

func projectName(_ cwd: String) -> String {
    cwd.contains("/scratch-workspaces/") ? "No folder" : (cwd as NSString).lastPathComponent
}

struct Mark: Codable, Equatable {
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
    var onHold: [String: Double]? = [:] // id -> when the user parked it
    var kindOverrides: [String: String]? = [:]   // id -> "review" or "own", the user's correction
    var ticketOverrides: [String: String]? = [:] // id -> the user's ticket key, "" for none
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
    var review: Bool? = nil        // reviewing a teammate's PR (true) or own work (false); missing in older records
    var ticket: String? = nil      // its Jira key and status, e.g. "PROJ-123 In Review"
    var reviewPRs: [String]? = nil // for a review, the PRs under review, as "repo#12"
    var todo: Bool? = nil          // a to-do the user added by hand
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
