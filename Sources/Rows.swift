// Task rows, cards and section headers.
import SwiftUI
import AppKit

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

// A link in a row's footer line, like a ticket or the PR under review; it opens in the browser
// rather than opening the session.
struct RowLink: Identifiable {
    let label: String
    let url: URL
    let help: String
    var id: String { url.absoluteString }
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
    var links: [RowLink] = []    // shown after `meta`, each its own click
    var metaTail: String? = nil  // after the links: when it last moved
    var duration: String? = nil  // how long the session has run, shown with a timer icon
    let clickable: Bool
    let help: String
    let onOpen: () -> Void
    @ViewBuilder let lines: () -> Lines
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false
    @ObservedObject private var renderCheck = RenderCheck.shared
    @Environment(\.forRender) private var forRender

    // Title and body lines beside the dot; below them, flush with the dot, the footer line:
    // badge and meta on the left, the hover actions on the right where they cover nothing.
    var body: some View {
        let showActions = hovering || (forRender && renderCheck.showActions)
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
                HStack(spacing: 0) {
                    // The project keeps its room first; the time at the end gives way.
                    Text(meta).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(2)
                    ForEach(links) { link in
                        Text(" · ").foregroundStyle(.tertiary).fixedSize()
                        Button(link.label) { NSWorkspace.shared.open(link.url) }
                            .buttonStyle(.plain).foregroundStyle(Color(nsColor: .linkColor).opacity(dimmed ? 0.6 : 0.9))
                            .lineLimit(1).layoutPriority(1).help(link.help)
                    }
                    if let metaTail { Text(" · " + metaTail).foregroundStyle(.tertiary).lineLimit(1) }
                }
                .font(.system(size: sizes.pt(.meta)))
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
            quietBadge: store.badgeIsQuiet(terminal: s.isTerminal), meta: meta, links: links, metaTail: metaTail,
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
        .contextMenu {
            if !s.deleted && s.scheduledTaskId == nil { corrections }
        }
    }

    // Right-click: set straight what the panel got wrong about a task.
    @ViewBuilder private var corrections: some View {
        Picker("This task is", selection: Binding(get: { store.kindOverride(s) ?? "auto" },
                                                  set: { store.setKind(s, $0 == "auto" ? nil : $0) })) {
            Text(store.kindOverride(s) == nil ? "Detected: " + (teamReview ? "a code review" : "my own work")
                                              : "Detect automatically").tag("auto")
            Text("A code review of a teammate's PR").tag("review")
            Text("My own work").tag("own")
        }
        .pickerStyle(.inline)
        Divider()
        let detected = store.ticketOverride(s) == nil
        Button(store.ticket(for: s).map { "Ticket: \($0)…" } ?? "Set ticket…") {
            if let key = askTicket(current: store.ticket(for: s)) { store.setTicket(s, key) }
        }
        if !detected {
            Button("Detect ticket automatically") { store.setTicket(s, nil) }
        } else if store.ticket(for: s) != nil {
            Button("No ticket") { store.setTicket(s, "") }
        }
    }

    // Where it runs; the ticket's status joins it as plain text when there's no Jira link for it.
    private var meta: String {
        let ticket = store.ticket(for: s).flatMap { store.ticketURL($0) } == nil ? store.ticketStatus(s) : nil
        return [s.project, s.branch, ticket].compactMap { $0 }.joined(separator: " · ")
    }

    // The ticket, opening in Jira; for a code review, the teammates' PRs under review instead.
    private var links: [RowLink] {
        if teamReview {
            return store.reviewedTeamPRs(s).prefix(2).compactMap { u in
                guard let url = URL(string: u) else { return nil }
                return RowLink(label: prLabel(u), url: url, help: "Open the PR under review on GitHub")
            }
        }
        guard let key = store.ticket(for: s), let url = store.ticketURL(key) else { return [] }
        return [RowLink(label: store.ticketStatus(s) ?? key, url: url, help: "Open \(key) in Jira")]
    }

    private var metaTail: String {
        if s.deleted { return "deleted" }
        let carried = s.lastActivity < Calendar.current.startOfDay(for: Date()) && !store.isDone(s) ? " · carried over" : ""
        return relative(s.lastActivity) + carried
    }
}

// Asks for a task's Jira key; nil when cancelled, "" for no ticket.
func askTicket(current: String?) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Ticket for this task"
    a.informativeText = "Its Jira key, like PROJ-123. Leave it empty for no ticket."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = current ?? ""
    field.placeholderString = "PROJ-123"
    a.accessoryView = field
    a.addButton(withTitle: "Save")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = field
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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
