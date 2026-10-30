// Shared look: motion, colours, text sizes and small controls.
import SwiftUI
import AppKit

// MARK: - Look

// How the list moves: a short, soft spring for the user's own actions, a gentler ease for
// changes a refresh brings in, so nothing jumps.
enum Motion {
    static let change = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let refresh = Animation.easeInOut(duration: 0.35)
    // A row leaving slides out to the side; one arriving drops in from just above.
    static let row = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: -6)),
        removal: .move(edge: .trailing).combined(with: .opacity))
}

enum Palette {
    static let needsYou = Color.orange
    static let active = Color.blue
    static let idle = Color.gray
    static let onHold = Color.indigo
    static let scheduled = Color.teal
    static let done = Color.green
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)  // the App badge
    static let terminal = Color(red: 0.35, green: 0.55, blue: 0.40) // the Terminal badge
    static let cowork = Color(red: 0.33, green: 0.47, blue: 0.72)   // the Cowork badge
    static let suggestion = Color.purple
    static let review = Color.pink  // the "Team code review" title prefix
    static let todo = Color(red: 0.12, green: 0.64, blue: 0.54)  // to-dos the user added by hand; deep enough to read as text
}

// The kinds of text whose size the user can set. Smaller text that goes with a kind (the
// badge next to the footer line, the count next to a section title) follows it by an offset.
enum TextRole: String, CaseIterable, Identifiable {
    case title, detail, meta, header, count
    var id: String { rawValue }

    var base: CGFloat {
        switch self {
        case .title: return 12.5
        case .detail: return 11
        case .meta: return 10
        case .header: return 12
        case .count: return 16
        }
    }

    var label: String {
        switch self {
        case .title: return "Task titles"
        case .detail: return "Status lines"
        case .meta: return "Footer line"
        case .header: return "Section titles"
        case .count: return "Counts"
        }
    }

    var hint: String {
        switch self {
        case .title: return "The bold name of each task"
        case .detail: return "Status, next step and Claude's suggestions"
        case .meta: return "App or Terminal badge, project, time"
        case .header: return "Section names and their counts"
        case .count: return "The numbers in the strip at the top"
        }
    }

    var sample: String {
        switch self {
        case .title: return "PROJ-123 Fix the export dialog's progress bar"
        case .detail: return "PR #42 review posted; awaiting approval"
        case .meta: return "web-app · 1 hr. ago · 2d 4h"
        case .header: return "Active"
        case .count: return "9"
        }
    }
}

// The user's text sizes, kept in UserDefaults. Views observe it, so a change applies at once.
final class TextSizes: ObservableObject {
    static let shared = TextSizes()
    static let range: ClosedRange<CGFloat> = -3...8  // how far each kind may move from its default
    private let key = "textSizes"
    @Published private(set) var sizes: [String: Double]

    init() { sizes = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }

    func size(_ role: TextRole) -> CGFloat { sizes[role.rawValue].map { CGFloat($0) } ?? role.base }

    // A size for text that goes with a kind: its size plus an offset, never below 7pt.
    func pt(_ role: TextRole, _ offset: CGFloat = 0) -> CGFloat { max(size(role) + offset, 7) }

    func step(_ role: TextRole, by delta: CGFloat) {
        let next = min(max(size(role) + delta, role.base + Self.range.lowerBound), role.base + Self.range.upperBound)
        sizes[role.rawValue] = Double(next)
        UserDefaults.standard.set(sizes, forKey: key)
    }

    var isDefault: Bool { TextRole.allCases.allSatisfy { size($0) == $0.base } }

    func reset() {
        sizes = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// Light or dark: as the system is set, or always one of them. Every colour in the panel is a
// system colour or a tint over one, so setting the app's appearance is all a theme takes.
enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// The user's theme, kept in UserDefaults and applied to the whole app as soon as it changes.
final class ThemeSetting: ObservableObject {
    static let shared = ThemeSetting()
    private let key = "theme"
    @Published var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: key)
            apply()
        }
    }

    init() { theme = UserDefaults.standard.string(forKey: key).flatMap(Theme.init) ?? .system }

    func apply() { NSApp.appearance = theme.appearance }
}

// Puts the enclosing scroll view on thin overlay scrollers that show only while scrolling,
// whatever the system's "Show scroll bars" setting says, so the list has no permanent bar.
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The system resets the style when that setting (or the attached mouse) changes.
            observer = observer ?? NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.apply() }
        }

        func apply() {
            DispatchQueue.main.async {
                guard let scroll = self.enclosingScrollView else { return }
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }
}

extension View {
    func overlayScrollers() -> some View { background(OverlayScrollers()) }

    // The grey the cards sit on: a touch darker than the window in light mode, lighter in dark.
    func canvas() -> some View {
        background(Color.primary.opacity(0.04)).background(Color(nsColor: .windowBackgroundColor))
    }
}

// Where a task runs: Code in the Claude desktop app, Cowork there, or `claude` in a terminal,
// told apart by icon alone to save room. A quiet badge is grey, for the source most tasks share;
// the others are in their colours.
struct SourceBadge: View {
    @ObservedObject private var sizes = TextSizes.shared
    let source: Source
    var quiet = false
    var todo = false  // the user's own to-do: always its own pill, so it never reads as a Claude task

    var body: some View {
        if todo {
            HStack(spacing: 3) {
                Image(systemName: "checklist").font(.system(size: sizes.pt(.meta, -2), weight: .semibold))
                Text("To-do").font(.system(size: sizes.pt(.meta, -1), weight: .semibold))
            }
            .foregroundStyle(Palette.todo)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Palette.todo.opacity(0.16)))
            .fixedSize()
            .help("A to-do you added")
        } else {
            let (symbol, help, color): (String, String, Color) = switch source {
            case .terminal: ("terminal", "Terminal", Palette.terminal)
            case .cowork: ("briefcase", "Cowork in the Claude app", Palette.cowork)
            case .app: ("macwindow", "Claude app", Palette.claude)
            }
            let icon = Image(systemName: symbol)
                .font(.system(size: sizes.pt(.meta, -0.5), weight: quiet ? .regular : .semibold))
                .help(help)
            if quiet {
                icon.foregroundStyle(.tertiary)
            } else {
                icon.foregroundStyle(color)
            }
        }
    }
}

// The header's controls share one height and shape: a pill, filled in its colour for the main
// action, tinted for the others; or, for an icon alone, a disc of the same height.
let headerControlHeight: CGFloat = 24

struct PillButton: View {
    let title: String?  // nil: the icon alone, in a disc
    var symbol: String? = nil
    let color: Color
    var filled = false
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini).tint(filled ? .white : color).scaleEffect(0.8).frame(width: 10, height: 10)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: title == nil ? 11 : 9.5, weight: .bold))
                }
                if let title { Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, title == nil ? 0 : 9)
            .frame(width: title == nil ? headerControlHeight : nil, height: headerControlHeight)
            .background(Capsule().fill(filled ? color.opacity(busy ? 0.7 : hovering ? 0.88 : 1)
                                              : color.opacity(hovering ? 0.24 : 0.13)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// The Triage button: the header's one filled pill, in Claude's coral.
struct TriageButton: View {
    let running: Bool
    var compact = false  // the icon alone, for a narrow panel
    let action: () -> Void

    var body: some View {
        PillButton(title: compact ? nil : running ? "Triaging…" : "Triage", symbol: "sparkles", color: Palette.claude,
                   filled: true, busy: running, action: action)
            .disabled(running)
    }
}

// A small hint that appears under a control after a short hover. Used where the system tooltip
// may not show, since this panel never becomes the active window.
struct HoverHint: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                guard inside else { withAnimation(.easeOut(duration: 0.1)) { shown = false }; return }
                let show = DispatchWorkItem { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
                pending = show
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: show)
            }
            .overlay(alignment: .topTrailing) {
                if shown {
                    Text(text)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 210, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .offset(y: 26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

extension View {
    func hoverHint(_ text: String) -> some View { modifier(HoverHint(text: text)) }
}

// A small icon button. With a tint it becomes a coloured disc in that section's colour,
// deepening on hover, like the count strip's numbers.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if let tint {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(tint.opacity(hovering ? 0.3 : 0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        } else {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .help(help)
        }
    }
}

// Set while rendering for a visual check, so hover-only controls show in the picture.
// Whether a view is the offscreen copy drawn for `render-now`. Only that copy follows
// RenderCheck, so a check never resizes, scrolls or opens settings on the user's own panel.
private struct ForRenderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var forRender: Bool {
        get { self[ForRenderKey.self] }
        set { self[ForRenderKey.self] = newValue }
    }
}

final class RenderCheck: ObservableObject {
    static let shared = RenderCheck()
    @Published var showActions = false
    @Published var jump: String?  // a section title, as if its count were clicked
    @Published var settings = false  // shows the settings page while rendering
    @Published var day: String?      // shows that past day while rendering
    @Published var search: String?   // searches for this while rendering
}
