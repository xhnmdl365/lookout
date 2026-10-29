// A past day: its summary and what was done.
import SwiftUI
import AppKit

// A day's Claude summary: generate, regenerate, or edit by hand.
struct SummaryBox: View {
    @ObservedObject private var sizes = TextSizes.shared
    let day: String
    @ObservedObject var store: Store
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let snap = store.loadSnapshot(day)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Palette.suggestion)
                Text("DAY SUMMARY").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                if snap?.summaryEdited == true {
                    Text("edited").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer()
                if store.summarizing == day {
                    ProgressView().controlSize(.mini)
                    Text("Summarizing…").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if editing {
                    Button("Save") { store.setSummary(day, draft); editing = false }
                    Button("Cancel") { editing = false }
                } else if snap != nil {
                    if snap?.summary != nil {
                        Button("Edit") { draft = snap?.summary ?? ""; editing = true }
                    }
                    Button(snap?.summary == nil ? "Summarize" : "Regenerate") { store.summarize(day) }
                        .help(snap?.summaryEdited == true ? "Replaces your edited summary" : "")
                }
            }
            .buttonStyle(.borderless).font(.system(size: 10, weight: .medium))
            if editing {
                TextEditor(text: $draft).font(.system(size: sizes.pt(.detail))).frame(height: 90)
            } else if let text = snap?.summary {
                SummaryText(text: text, size: sizes.pt(.detail, 0.5))
            } else if snap == nil {
                Text("No snapshot for this day").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.suggestion.opacity(0.06)))
        .padding(.horizontal, 12).padding(.top, 12)
    }
}

// Claude writes the summary in Markdown: "- " lines and lines led by a status emoji get a
// hanging indent, and
// **bold**, *italic* and `code` are drawn rather than shown as symbols.
struct SummaryText: View {
    let text: String
    let size: CGFloat

    var body: some View {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let item = ["- ", "* ", "• "].first(where: line.hasPrefix).map({ String(line.dropFirst($0.count)) }) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item)
                    }
                } else if let mark = line.first, mark.unicodeScalars.first?.properties.isEmojiPresentation == true {
                    // A status emoji leads its line; wrapped text lines up after it.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(mark))
                        inline(line.dropFirst().trimmingCharacters(in: .whitespaces))
                    }
                } else if let lead = ["Next:", "Overall:"].first(where: line.hasPrefix) {
                    inline("**\(lead)**" + line.dropFirst(lead.count))
                } else {
                    inline(line.hasPrefix("#") ? "**" + line.drop { $0 == "#" || $0 == " " } + "**" : line)
                }
            }
        }
        .font(.system(size: size))
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> some View {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(s))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// A task in a past day's snapshot. Corrections are recorded on that day only.
struct SnapRow: View {
    @ObservedObject private var sizes = TextSizes.shared
    let t: SnapTask
    let day: String
    let snap: DaySnapshot
    @ObservedObject var store: Store

    var body: some View {
        let done = snap.isDone(t)
        let corrected = snap.userDone?[t.id] != nil
        let terminal = t.id.hasPrefix("cli_"), todo = t.id.hasPrefix("todo_")
        let tint: Color = t.deleted ? .gray.opacity(0.4) : done ? Palette.done
            : ["needsYou": Palette.needsYou, "active": Palette.active, "onHold": Palette.onHold,
               "todo": Palette.todo][t.section] ?? Palette.idle
        RowShell(
            tint: tint, title: t.title, titleDone: done, dimmed: done || t.deleted, pinned: false,
            terminal: terminal, todo: todo, quietBadge: store.badgeIsQuiet(terminal: terminal),
            meta: t.project + (t.deleted ? " · deleted" : "") + (corrected ? " · corrected by hand" : ""),
            clickable: !t.deleted && !todo,
            help: todo ? "A to-do you added" : openHelp(deleted: t.deleted, terminal: terminal),
            onOpen: { store.open(t.id) }
        ) {
            if done {
                Label(t.doneReason ?? "Marked done by hand", systemImage: "checkmark.circle")
                    .font(.system(size: sizes.pt(.detail))).foregroundStyle(.secondary).lineLimit(2)
            } else if let d = t.detail {
                Text(d).font(.system(size: sizes.pt(.detail))).foregroundStyle(.secondary).lineLimit(2)
            }
        } actions: {
            IconButton(symbol: done ? "arrow.uturn.backward" : "checkmark",
                       help: done ? "Not done that day" : "Mark done that day",
                       tint: done ? Palette.needsYou : Palette.done) { store.setDone(day, t, !done) }
        }
    }
}

// A past day, read from its snapshot.
struct DayView: View {
    let day: String
    @ObservedObject var store: Store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                SummaryBox(day: day, store: store)
                if let snap = store.loadSnapshot(day) {
                    let start = dayDate(day).timeIntervalSince1970
                    let worked = { (t: SnapTask) in t.lastActivity >= start && t.lastActivity < start + 86400 }
                    group("Done that day", Palette.done, snap.tasks.filter(snap.isDone), snap)
                    group("Progressed", Palette.active,
                          snap.tasks.filter { !snap.isDone($0) && $0.section != "onHold" && worked($0) }, snap)
                    group("Still open", Palette.idle,
                          snap.tasks.filter { !snap.isDone($0) && $0.section != "onHold" && !worked($0) }, snap)
                    group("Parked", Palette.onHold, snap.tasks.filter { !snap.isDone($0) && $0.section == "onHold" }, snap)
                    Text("Snapshot as of \(Date(timeIntervalSince1970: snap.updatedAt).formatted(date: .omitted, time: .shortened)). Since then only your own edits change it.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).padding(16)
                }
            }
            .padding(.bottom, 8)
            .overlayScrollers()
        }
    }

    @ViewBuilder private func group(_ title: String, _ tint: Color, _ items: [SnapTask], _ snap: DaySnapshot) -> some View {
        if !items.isEmpty {
            Section {
                Card(items: items) { SnapRow(t: $0, day: day, snap: snap, store: store) }
            } header: {
                SectionHeader(title: title, count: items.count, tint: tint, collapsible: false, open: true, toggle: {})
            }
        }
    }
}

// A month calendar for jumping to a day. Days with a record can be picked and carry a dot;
// the rest are greyed out. Today is ringed; the day on screen is filled.
struct DayCalendar: View {
    let recorded: Set<String>  // days with a snapshot, as "yyyy-MM-dd"
    let selected: String
    let today: String
    let pick: (String) -> Void
    @State private var month: Date

    init(recorded: Set<String>, selected: String, today: String, pick: @escaping (String) -> Void) {
        self.recorded = recorded
        self.selected = selected
        self.today = today
        self.pick = pick
        _month = State(initialValue: DayCalendar.calendar.dateInterval(of: .month, for: dayDate(selected))?.start ?? Date())
    }

    // English names, but the user's own first day of the week.
    private static var calendar: Calendar {
        var c = Calendar.current
        let firstWeekday = c.firstWeekday
        c.locale = english
        c.firstWeekday = firstWeekday
        return c
    }

    private var firstMonth: Date {
        let first = recorded.min().map(dayDate) ?? Date()
        return Self.calendar.dateInterval(of: .month, for: first)?.start ?? first
    }
    private var thisMonth: Date { Self.calendar.dateInterval(of: .month, for: Date())?.start ?? Date() }

    // The month's days as keys, after blanks for the weekdays before the 1st.
    private var cells: [String?] {
        let cal = Self.calendar
        let count = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let days = (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: month).map(dayKey) }
        return Array(repeating: nil, count: lead) + days
    }

    private var weekdays: [String] {
        let cal = Self.calendar
        let symbols = cal.shortStandaloneWeekdaySymbols.map { String($0.prefix(2)) }
        return Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                Text(month.formatted(Date.FormatStyle(locale: english).month(.wide).year()))
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                IconButton(symbol: "chevron.left", help: "Previous month") { step(-1) }
                    .disabled(month <= firstMonth)
                IconButton(symbol: "chevron.right", help: "Next month") { step(1) }
                    .disabled(month >= thisMonth)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 7), spacing: 2) {
                ForEach(weekdays, id: \.self) {
                    Text($0).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(height: 18)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, key in
                    if let key { DayCell(key: key, recorded: recorded.contains(key) || key == today,
                                         selected: key == selected, today: key == today) { pick(key) } }
                    else { Color.clear.frame(height: 28) }
                }
            }
            Text("\(recorded.count) day\(recorded.count == 1 ? "" : "s") recorded")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 228)
    }

    private func step(_ months: Int) {
        if let m = Self.calendar.date(byAdding: .month, value: months, to: month) {
            withAnimation(Motion.change) { month = m }
        }
    }
}

private struct DayCell: View {
    let key: String
    let recorded: Bool
    let selected: Bool
    let today: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(String(Int(key.suffix(2)) ?? 0))
                    .font(.system(size: 12, weight: selected || today ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : recorded ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                Circle().fill(selected ? Color.white.opacity(0.8) : Palette.claude)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(recorded && !today ? 1 : 0)
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(selected ? Palette.claude : hovering && recorded ? Palette.claude.opacity(0.12) : .clear))
            .overlay(Circle().strokeBorder(Palette.claude.opacity(today && !selected ? 0.8 : 0), lineWidth: 1.2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!recorded)
        .onHover { hovering = $0 }
    }
}
