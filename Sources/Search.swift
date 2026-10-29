// Search: every task the panel knows, open or closed, matched on what its row shows and what
// it is about. All in memory, so it answers as you type.
import Foundation

// A query's lower-cased words; a task matches when it holds them all.
func searchWords(_ query: String) -> [String] {
    query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
}

// "Today", "Yesterday", else the weekday and date, with the year when it isn't this one.
func dayTitle(_ day: String) -> String {
    let today = dayKey(Date())
    if day == today { return "Today" }
    if let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()), day == dayKey(y) { return "Yesterday" }
    let date = dayDate(day)
    let style = Date.FormatStyle(locale: english).weekday(.abbreviated).month(.abbreviated).day()
    return day.prefix(4) == today.prefix(4) ? date.formatted(style) : date.formatted(style.year())
}

extension Store {
    func makeSearchText(_ s: Session) -> String {
        var parts = [s.title, s.detail, s.nextStep, s.project, s.branch, s.gitBranch, ticket(for: s), mark(s)?.reason]
            .compactMap { $0 }
        parts += s.workBranches + s.prs.map { prLabel($0.url) } + s.reviewRefs
        return parts.joined(separator: "\n").lowercased()
    }

    func matches(_ s: Session, _ words: [String]) -> Bool {
        let text = searchText(s)
        return words.allSatisfy { text.contains($0) }
    }

    // A listed task matches when it or a session started from it does.
    func familyMatches(_ s: Session, _ words: [String]) -> Bool {
        matches(s, words) || children(of: s).contains { matches($0, words) }
    }

    // Closed tasks that match and aren't in today's list: done before today, archived or
    // deleted. Newest first, grouped by the day they closed, at most `limit` of them; `more`
    // counts the rest. Scheduled runs are left out.
    func earlierMatches(_ words: [String], limit: Int) -> (groups: [(day: String, tasks: [Session])], more: Int) {
        let listed = Set(doneToday.map(\.id))
        // When it closed: the day it was marked done; but a session found archived was marked
        // when the panel noticed, which can be long after, so its last activity says more.
        let closedAt = { (s: Session) -> Date in
            guard let m = self.mark(s), !(m.auto && s.archived) else { return s.lastActivity }
            return max(s.lastActivity, Date(timeIntervalSince1970: m.at))
        }
        let found = sessions
            .filter { $0.scheduledTaskId == nil && baseSection($0) == nil && !listed.contains($0.id) && matches($0, words) }
            .sorted { closedAt($0) > closedAt($1) }
        var groups: [(day: String, tasks: [Session])] = []
        for s in found.prefix(limit) {
            let day = dayKey(closedAt(s))
            if groups.last?.day == day { groups[groups.count - 1].tasks.append(s) } else { groups.append((day, [s])) }
        }
        return (groups, max(0, found.count - limit))
    }
}
