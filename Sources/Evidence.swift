// Hard evidence that a task ended: PR state from gh, ticket status from acli, team reviews.
import SwiftUI
import AppKit

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

extension Store {
    func prEvidence(_ s: Session) -> String? {
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
    func reviewEvidence(_ s: Session) -> String? {
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
    func ticketEvidence(_ s: Session) -> String? {
        guard !teamReviews.contains(s.id), let key = ticketKey(s.title), let t = tickets[key], t.done else { return nil }
        if let c = t.changedAt, s.lastActivity.timeIntervalSince1970 > c + prGraceHours * 3600 { return nil }
        return "Ticket \(key) \(t.status)"
    }

    // Whether Jira, not PRs, settles this task: own work whose ticket acli could read.
    func ticketDecides(_ s: Session) -> Bool {
        !teamReviews.contains(s.id) && ticketKey(s.title).flatMap { tickets[$0] } != nil
    }

    // The ticket's current status, for the footer line of own work.
    func ticketStatus(_ s: Session) -> String? {
        guard !teamReviews.contains(s.id), let key = ticketKey(s.title) else { return nil }
        return tickets[key]?.status
    }

    private func reviewText(_ s: Session) -> String { [s.title, s.detail ?? "", s.needs ?? ""].joined(separator: "\n") }

    // Which PRs each open task names, and which tasks are team code reviews.
    func updateReviews(_ all: [Session]) {
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

    func refreshPRs() {
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
}
