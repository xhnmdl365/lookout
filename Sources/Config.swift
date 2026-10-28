// Data locations, the optional config.json, external tools and the optional naming rule.
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
let todosURL = dataDir.appendingPathComponent("todos.json")
let summaryInputURL = dataDir.appendingPathComponent("summary-input.json")  // what the last day summary was given
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
    var jiraSite: String?      // e.g. "yourteam.atlassian.net", for ticket links; else acli's site
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
    var site: String? = nil  // Jira: the site acli is signed in to

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
                                   fix: ok ? nil : "acli jira auth login --web", site: ok ? site : nil))
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
//   blocked, <= 14 days            -> "Attention"
//   activity within 36h, or pinned -> "Active"
//   anything else still open       -> "Idle lately", however old (finished or parked?)
//   parked (manual)                -> "Parked": no age limit, skipped by Claude, back to normal on new activity
// Auto-done, hard evidence only:
//   layer 1 (here):   tracked session archived / deleted; all its PRs merged or closed (gh refreshed)
//                     and no work in the session after the last merge (beyond prGraceHours)
//   layer 2 (Claude): a PR named in the task's status (e.g. the PR under review) merged or closed
// Layer 3 (Claude, no hard evidence): a suggestion the user accepts or ignores.
// Each day's view is kept as a snapshot (days/<date>.json), rewritten only while that day lasts;
// afterwards only the user's own edits change it.
let activeHours = config.activeHours ?? 36
let scheduledDays = config.scheduledDays ?? 7    // a scheduled task's latest run shows this long
let blockedDays = config.blockedDays ?? 14       // blocked longer than this counts as idle, not "Attention"
let prRefreshMinutes = config.refreshMinutes ?? 10  // how often PRs and tickets are checked
let prGraceHours = config.prGraceHours ?? 6      // activity this long after the last merge still counts as wrap-up
let reverifyHours = config.reverifyHours ?? 24   // an unchanged task's verdict is checked again after this long
