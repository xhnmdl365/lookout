// The panel: count strip, sections and footer.
import SwiftUI
import AppKit

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
    var forRender = false  // the offscreen copy `render-now` draws
    @State private var toggled: Set<String> = []  // collapsible sections flipped from their default
    @State private var viewDay: String?  // nil: today, live
    @State private var jumpTo: String?   // a section the count strip asked to scroll to
    @State private var showSettings = false
    @State private var picking = false  // the calendar for jumping to a day is open

    private var specs: [SectionSpec] {
        [
            SectionSpec(title: "Needs you", short: "Needs you", tint: Palette.needsYou, items: store.needsYou),
            SectionSpec(title: "To-do", short: "To-do", tint: Palette.todo, items: store.todoTasks),
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
                            .minimumScaleFactor(0.65)  // a narrow panel shrinks the labels rather than running them together
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 5).padding(.horizontal, 1.5)
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
                if viewDay == nil, store.triageEnabled, let err = store.judge?.error {
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
        .onReceive(RenderCheck.shared.$settings) { if forRender { showSettings = $0 } }
        .onReceive(RenderCheck.shared.$day) { if forRender, let d = $0 { viewDay = d } }
        .environment(\.forRender, forRender)
    }

    // A calendar of the recorded days, for days too far back to page to.
    private var dayPicker: some View {
        DayCalendar(recorded: Set(store.days), selected: viewDay ?? today, today: today) { key in
            viewDay = key >= today ? nil : key
            picking = false
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: "Previous day") { viewDay = prevDay }
                .disabled(prevDay == nil)
            // The date opens a calendar, for days too far back to page to.
            Button { picking = true } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(dayDate(viewDay ?? today).formatted(
                        Date.FormatStyle(locale: english).weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.system(size: 14, weight: .bold))
                    Text(viewDay == nil ? "Today" : "History")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .fixedSize()  // the date keeps its one line; the controls on the right give way instead
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pick a day")
            .popover(isPresented: $picking, arrowEdge: .bottom) { dayPicker }
            IconButton(symbol: "chevron.right", help: "Next day") { viewDay = nextDay }
                .disabled(viewDay == nil)
            Spacer(minLength: 6)
            // Wide enough, the to-do button says what it adds; narrow, it keeps just its icon.
            ViewThatFits(in: .horizontal) {
                headerControls(compact: false)
                headerControls(compact: true)
            }
            .layoutPriority(1)  // measured before the spacer takes what's left
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    // The header's right side, one height throughout: the page's own actions as pills (Triage the
    // only filled one), then settings as a disc at the end.
    private func headerControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if showSettings {
                PillButton(title: "Done", color: Palette.claude) { showSettings = false }
            } else {
                if viewDay != nil {
                    PillButton(title: "Today", symbol: "arrow.uturn.backward", color: Palette.active) { viewDay = nil }
                        .help("Back to today")
                } else {
                    PillButton(title: compact ? nil : "To-do", symbol: "plus", color: Palette.todo) {
                        withAnimation(Motion.change) { store.addingTodo = true }
                        reveal("To-do")
                    }
                    .help("Add a to-do of your own")
                    if store.triageEnabled {
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
                PillButton(title: nil, symbol: "gearshape", color: .secondary) { showSettings = true }
                    .help("Settings: AI triage, integrations, text size")
            }
        }
    }

    private var live: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // A plain stack, all rows laid out: a lazy one only guessed the height of sections it
            // hadn't drawn, so jumps landed short and kept correcting themselves (the flicker).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(specs, id: \.title) { section($0) }
                if store.needsYou.isEmpty && store.todoTasks.isEmpty && !store.addingTodo
                    && store.active.isEmpty && store.idle.isEmpty {
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
            guard forRender else { return }
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
        let adding = spec.title == "To-do" && store.addingTodo
        if !spec.items.isEmpty || adding {
            let open = isOpen(spec)
            Section {
                if adding {
                    TodoEditor(title: "", note: "", saveLabel: "Add",
                               save: { store.addTodo(title: $0, note: $1) },
                               cancel: { withAnimation(Motion.change) { store.addingTodo = false } })
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.todo.opacity(0.5)))
                        .padding(.horizontal, 10).padding(.bottom, spec.items.isEmpty ? 0 : 6)
                        .transition(.opacity)
                }
                if open && !spec.items.isEmpty {
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
