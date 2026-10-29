// Hard evidence that a task ended: PR state from gh, ticket status from acli, team reviews.
import SwiftUI
import AppKit

// Compiled patterns, kept: rows look up tickets and PRs on every redraw. NSCache is thread-safe,
// and PR refreshes run off the main thread.
private let regexCache = NSCache<NSString, NSRegularExpression>()

// Each match's capture groups (index 0 is the whole match).
func captures(_ pattern: String, in s: String) -> [[String]] {
    let re: NSRegularExpression
    if let cached = regexCache.object(forKey: pattern as NSString) {
        re = cached
    } else {
        guard let made = try? NSRegularExpression(pattern: pattern) else { return [] }
        regexCache.setObject(made, forKey: pattern as NSString)
        re = made
    }
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

// Jira-looking keys in a branch name, where they're often lower case: "feature/proj-123-login".
// Only a guess: a key counts once Jira knows it.
func branchTicketKeys(_ branch: String) -> [String] {
    captures(#"(?<![A-Za-z0-9])([A-Za-z][A-Za-z0-9]{1,9}-\d+)(?![0-9])"#, in: branch).map { $0[1].uppercased() }
}

// One PR's state, merge or close time, author, branch, title and reviewers, from gh.
func prInfo(gh: String, url: String) -> PRInfo? {
    guard let out = run(gh, ["pr", "view", url, "--json", "state,mergedAt,closedAt,author,headRefName,title,reviewRequests,latestReviews"]),
          let o = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
          let state = o["state"] as? String else { return nil }
    let iso = ISO8601DateFormatter()
    let end = (o["mergedAt"] as? String).flatMap(iso.date) ?? (o["closedAt"] as? String).flatMap(iso.date)
    let loginOf = { (d: Any?) in (d as? [String: Any])?["login"] as? String }
    let requested = (o["reviewRequests"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
    let reviewed = (o["latestReviews"] as? [[String: Any]] ?? []).compactMap { loginOf($0["author"]) }
    return PRInfo(state: state, endedAt: end?.timeIntervalSince1970, author: loginOf(o["author"]),
                  branch: o["headRefName"] as? String, title: o["title"] as? String, reviewers: Set(requested + reviewed))
}

// A PR URL as people write it: "repo#12".
func prLabel(_ url: String) -> String {
    let parts = URL(string: url)?.pathComponents ?? []  // ["/", owner, repo, "pull", n]
    return parts.count >= 5 ? "\(parts[2])#\(parts[4])" : url
}

// A PR ref from a gh command as a URL: "owner/repo#12", or "#12" in the session's own repo.
func resolveReviewRef(_ ref: String, repo: String?) -> String? {
    if ref.hasPrefix("http") { return captures(#"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)"#, in: ref).first
        .map { "https://github.com/\($0[1])/\($0[2])/pull/\($0[3])" } }
    let parts = ref.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, let n = Int(parts[1]), let r = parts[0].isEmpty ? repo : parts[0] else { return nil }
    return "https://github.com/\(r)/pull/\(n)"
}

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

    // Where a task's ticket may be named, best first: its title, its branches, then its own PRs'
    // branches and titles. Branch and PR keys are guesses until Jira confirms them.
    // Sessions sharing a folder share its branch and the PR the Claude app links to it, so those
    // count only for a session in its own worktree; elsewhere only branches the session checked
    // out or pushed, and PRs it names or looked at, are its own.
    func ticketCandidates(_ s: Session) -> [String] {
        var keys = [ticketKey(s.title)].compactMap { $0 }
        // The latest branch first: a session that moved on to another ticket is about that one.
        keys += ((s.runCwd != s.cwd ? [s.gitBranch].compactMap { $0 } : []) + s.workBranches.reversed()).flatMap(branchTicketKeys)
        for url in ownPRs(s, textRefs[s.id] ?? []) {
            guard let pr = prLive[url], let me, pr.author == me else { continue }
            keys += (pr.branch.map(branchTicketKeys) ?? []) + [pr.title.flatMap(ticketKey)].compactMap { $0 }
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    // The ticket a task is about: the user's own say first, then the first candidate Jira knows,
    // else the title's key. Team code reviews have none: the PR under review decides those.
    func ticket(for s: Session) -> String? {
        if let k = manual.ticketOverrides?[s.id] { return k.isEmpty ? nil : k }
        guard !teamReviews.contains(s.id), !s.isTodo else { return nil }
        let keys = ticketCandidates(s)
        return keys.first { tickets[$0] != nil } ?? ticketKey(s.title)
    }

    // Own work on a ticket: Jira decides. Done once the ticket is in Jira's Done category and the
    // session hasn't been worked in since it got there.
    func ticketEvidence(_ s: Session) -> String? {
        guard let key = ticket(for: s), let t = tickets[key], t.done else { return nil }
        if let c = t.changedAt, s.lastActivity.timeIntervalSince1970 > c + prGraceHours * 3600 { return nil }
        return "Ticket \(key) \(t.status)"
    }

    // Whether Jira, not PRs, settles this task: own work whose ticket acli could read.
    func ticketDecides(_ s: Session) -> Bool { ticket(for: s).flatMap { tickets[$0] } != nil }

    // The ticket's key and current status, for the footer line of own work.
    func ticketStatus(_ s: Session) -> String? {
        guard let key = ticket(for: s), let status = tickets[key]?.status else { return nil }
        return "\(key) \(status)"
    }

    // A ticket's page in Jira, once the site is known.
    func ticketURL(_ key: String) -> URL? {
        guard let site = jiraSite?.replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")), !site.isEmpty else { return nil }
        return URL(string: "https://\(site)/browse/\(key)")
    }

    // The teammates' PRs a code review is about: those it names or looked at whose author isn't
    // the user, else, before gh has said who wrote them, the ones it checked out or reviewed.
    func reviewedTeamPRs(_ s: Session) -> [String] {
        let refs = textRefs[s.id] ?? []
        if let me {
            let theirs = refs.filter { prLive[$0]?.author.map { $0 != me } ?? false }
            if !theirs.isEmpty { return theirs }
        }
        return reviewedPRs(s, repos: repoByCwd)
    }

    private func reviewText(_ s: Session) -> String { [s.title, s.detail ?? "", s.needs ?? ""].joined(separator: "\n") }

    // The PRs among `urls` that are the session's own doing: all of them in its own worktree;
    // elsewhere, not the folder's PR the Claude app links to every session there.
    func ownPRs(_ s: Session, _ urls: [String]) -> [String] {
        s.runCwd != s.cwd ? urls : urls.filter { u in !s.prs.contains { $0.url == u } }
    }

    // PRs the session checked out or reviewed with gh, as URLs; with `diffs`, also those it only
    // diffed or viewed.
    func reviewedPRs(_ s: Session, repos: [String: String?], diffs: Bool = false) -> [String] {
        (s.reviewRefs + (diffs ? s.diffRefs : [])).compactMap { resolveReviewRef($0, repo: repos[s.cwd] ?? nil) }
    }

    // Every PR a task touches: linked by the app, named in its text, or looked at with gh.
    func taskPRs(_ s: Session, repos: [String: String?]) -> [String] {
        let named = prRefs(in: reviewText(s), repo: repos[s.cwd] ?? nil, defaultOwner: config.githubOrg ?? commonOwner(repos))
        var seen = Set<String>()
        return (s.prs.map(\.url) + named + reviewedPRs(s, repos: repos, diffs: true)).filter { seen.insert($0).inserted }
    }

    // Which PRs each open task touches, and which tasks are team code reviews. A review is
    // told by what the session did, not what it's called: the user's own say first; then a
    // "Team code review" title. A session that pushed a branch or opened a PR is the user's own
    // work, as is one titled with a ticket and no word of a review. Otherwise it's a review when
    // it checked out or reviewed a teammate's PR with gh; or diffed, viewed or names a teammate's PR
    // that GitHub lists the user as a reviewer on; or, last, talks of a review next to a teammate's
    // PR, named or looked at.
    func updateReviews(_ all: [Session]) {
        var refs: [String: [String]] = [:], team = Set<String>()
        let overrides = manual.kindOverrides ?? [:]
        for s in all where !s.archived && !s.deleted && s.scheduledTaskId == nil && !s.isTodo {
            let r = taskPRs(s, repos: repoByCwd)
            if !r.isEmpty { refs[s.id] = r }
            if let o = overrides[s.id] {
                if o == "review" { team.insert(s.id) }
                continue
            }
            if namedTeamReview(s.title) { team.insert(s.id); continue }
            let titledOwn = ticketKey(s.title) != nil && s.title.range(of: "review", options: .caseInsensitive) == nil
            guard let me, !s.pushed, !titledOwn else { continue }
            let theirs = { (url: String) in self.prLive[url]?.author.map { $0 != me } ?? false }
            let asked = { (url: String) in theirs(url) && self.prLive[url]?.reviewers.contains(me) == true }
            if reviewedPRs(s, repos: repoByCwd).contains(where: theirs)
                || (ownPRs(s, r) + reviewedPRs(s, repos: repoByCwd, diffs: true)).contains(where: asked)
                || (reviewText(s).range(of: "review", options: .caseInsensitive) != nil && r.contains(where: theirs)) {
                team.insert(s.id)
            }
        }
        textRefs = refs
        teamReviews = team
    }

    // `then` runs on the main queue once the new states are in, before the reload they trigger.
    func refreshPRs(then: (() -> Void)? = nil) {
        // Open tasks' PRs, their own and those named in their text. Open ones may have changed;
        // finished ones need their merge time once; ones gh can't find are not asked again.
        let open = sessions.filter { !$0.archived && !$0.deleted && !isDone($0) && !isOnHold($0) && $0.scheduledTaskId == nil && !$0.isTodo }
        let folders = Set(open.map(\.cwd)).filter { repoByCwd[$0] == nil }
        let live = prLive, knownRepos = repoByCwd, needMe = me == nil
        // Own work's ticket candidates; keys from PRs gh is about to read are added below.
        let ownWork = open.filter { manual.ticketOverrides?[$0.id] == nil && !teamReviews.contains($0.id) }
        let knownKeys = Set(open.compactMap { manual.ticketOverrides?[$0.id] }.filter { !$0.isEmpty }
                            + ownWork.flatMap(ticketCandidates))
        let skip = ticketMissing, knownMe = me
        let gh = Tools.gh, acliPath = Tools.acli  // either may be missing; its checks are then skipped
        DispatchQueue.global(qos: .utility).async {
            var repos = knownRepos
            for f in folders { repos[f] = .some(githubRepo(of: f)) }
            let login = needMe ? gh.map { shell($0, ["api", "user", "-q", ".login"]).trimmingCharacters(in: .whitespacesAndNewlines) } : nil
            let urls = Set(open.flatMap { self.taskPRs($0, repos: repos) })
                .filter { gh != nil && (live[$0] == nil || live[$0]?.state == "OPEN") }
            var found: [String: PRInfo] = [:]
            for u in urls {
                found[u] = gh.flatMap { prInfo(gh: $0, url: u) } ?? PRInfo(state: "UNKNOWN")
            }
            // Tickets, read with the Atlassian CLI when it is installed. Their status can move
            // either way, so every one is read again each time; keys Jira doesn't know are dropped.
            var keys = knownKeys
            if let me = knownMe ?? login {
                for s in ownWork {
                    for u in self.ownPRs(s, self.taskPRs(s, repos: repos)) {
                        guard let pr = found[u] ?? live[u], pr.author == me else { continue }
                        keys.formUnion((pr.branch.map(branchTicketKeys) ?? []) + [pr.title.flatMap(ticketKey)].compactMap { $0 })
                    }
                }
            }
            keys.subtract(skip)
            var foundTickets: [String: (status: String, done: Bool, changedAt: Double?)] = [:]
            var missing = Set<String>()
            if let acli = acliPath {
                for k in keys {
                    let out = shell(acli, ["jira", "workitem", "view", k, "--json", "--fields", "status,statuscategorychangedate"])
                    if let t = parseTicket(out) { foundTickets[k] = t } else { missing.insert(k); log("acli: no status for \(k)") }
                }
                log("acli: read \(foundTickets.count) of \(keys.count) tickets: \(foundTickets.keys.sorted().joined(separator: " "))")
            }
            DispatchQueue.main.async {
                self.repoByCwd = repos
                if let login, !login.isEmpty { self.me = login }
                self.prLive.merge(found) { _, new in new }
                self.tickets.merge(foundTickets) { _, new in new }
                self.ticketMissing.formUnion(missing)
                self.updateReviews(self.sessions)  // authors and reviewers just came in
                then?()
                self.reload()
            }
        }
    }
}
