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

// Claude writes the summary in Markdown: "- " lines become bullets with a hanging indent, and
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
        let terminal = t.id.hasPrefix("cli_")
        let tint: Color = t.deleted ? .gray.opacity(0.4) : done ? Palette.done
            : ["needsYou": Palette.needsYou, "active": Palette.active, "onHold": Palette.onHold][t.section] ?? Palette.idle
        RowShell(
            tint: tint, title: t.title, titleDone: done, dimmed: done || t.deleted, pinned: false,
            terminal: terminal, quietBadge: store.badgeIsQuiet(terminal: terminal),
            meta: t.project + (t.deleted ? " · deleted" : "") + (corrected ? " · corrected by hand" : ""),
            clickable: !t.deleted, help: openHelp(deleted: t.deleted, terminal: terminal),
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
                    group("On hold", Palette.onHold, snap.tasks.filter { !snap.isDone($0) && $0.section == "onHold" }, snap)
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
