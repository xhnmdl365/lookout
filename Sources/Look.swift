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
    static let suggestion = Color.purple
    static let review = Color.pink  // the "Team code review" title prefix
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
        case .header: return "In progress"
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

// Where a task runs: the Claude desktop app, or `claude` in a terminal. A quiet badge is just
// a grey icon, for the source most tasks share; the other is a coloured pill.
struct SourceBadge: View {
    @ObservedObject private var sizes = TextSizes.shared
    let terminal: Bool
    var quiet = false

    var body: some View {
        let color = terminal ? Palette.terminal : Palette.claude
        if quiet {
            Image(systemName: terminal ? "terminal" : "macwindow")
                .font(.system(size: sizes.pt(.meta, -0.5)))
                .foregroundStyle(.tertiary)
                .help(terminal ? "Terminal" : "Claude app")
        } else {
            pill(color)
        }
    }

    private func pill(_ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: terminal ? "terminal" : "macwindow")
                .font(.system(size: sizes.pt(.meta, -2), weight: .semibold))
            Text(terminal ? "Terminal" : "App")
                .font(.system(size: sizes.pt(.meta, -1), weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

// The Triage button: a compact pill in Claude's coral.
struct TriageButton: View {
    let running: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if running {
                    ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.8).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold))
                }
                Text(running ? "Triaging…" : "Triage").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(Palette.claude.opacity(running ? 0.7 : hovering ? 0.88 : 1)))
        }
        .buttonStyle(.plain)
        .disabled(running)
        .onHover { hovering = $0 }
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
}
