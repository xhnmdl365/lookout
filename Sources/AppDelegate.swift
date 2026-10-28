// The floating panel, the menu bar icon and the debug triggers.
import SwiftUI
import AppKit

// The panel floats beside whatever app the user works in, so a click on it should act at once,
// not just bring it forward and wait for a second click. Views decide that one by one, and the
// ones SwiftUI makes inside a scroll view say no; becoming key before the click is handled
// makes it an ordinary click for all of them.
final class FloatingPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var renderTimer: Timer?
    var store: Store!
    var renderWindow: NSWindow?  // the offscreen copy being drawn for render-now
    var pendingJump: String?

    @objc func showPanel() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
    }
    @objc func quit() { NSApp.terminate(nil) }

    // Closing the panel (close button or Esc) only hides it; the menu bar icon brings it back.
    func windowWillClose(_ notification: Notification) {
        log("panel closed (event: \(NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "none"))")
    }

    func applicationWillTerminate(_ notification: Notification) { log("terminate") }

    // Opening the app again (Finder, Spotlight, `open`) brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // A `render-now` file in the data folder saves the panel as render.png, for checking the
    // look without screen-recording permission. It draws an offscreen copy of the panel, so the
    // user's own panel never moves. A number in the file renders at that height; the word
    // "actions" shows every row's hover buttons, "settings" the settings page, "yesterday"
    // the latest past day, "calendar" the day picker on its own, and "w420" a width of 420.
    @objc func renderIfAsked() {
        // A `triage-now` file runs Triage, over every listed task when it says "all"; "dry" only
        // writes the task list Claude would get.
        let triage = dataDir.appendingPathComponent("triage-now")
        if let words = try? String(contentsOf: triage, encoding: .utf8) {
            try? FileManager.default.removeItem(at: triage)
            store.runJudge(all: words.contains("all"), dry: words.contains("dry"))
        }
        // A `summarize-now` file holding a day ("2026-01-31") has Claude summarize it again.
        let summarizeFile = dataDir.appendingPathComponent("summarize-now")
        if let day = try? String(contentsOf: summarizeFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: summarizeFile)
            store.summarize(day.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A `jump-now` file holding a section title scrolls the next render to that section.
        let jump = dataDir.appendingPathComponent("jump-now")
        if let title = try? String(contentsOf: jump, encoding: .utf8) {
            try? FileManager.default.removeItem(at: jump)
            pendingJump = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trigger = dataDir.appendingPathComponent("render-now")
        guard renderWindow == nil, let request = try? String(contentsOf: trigger, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: trigger)
        let words = request.split(whereSeparator: \.isWhitespace)
        let width = words.first { $0.hasPrefix("w") }.flatMap { Double($0.dropFirst()) } ?? panel.frame.width
        let size = NSSize(width: width,
                          height: words.compactMap { Double($0) }.first ?? panel.contentView?.bounds.height ?? 600)
        // Borderless windows aren't kept on screen, so this one draws far off it.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let today = dayKey(Date())
        let root = words.contains("calendar")
            ? AnyView(DayCalendar(recorded: Set(store.days), selected: today, today: today) { _ in }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)))
            : AnyView(ContentView(store: store, forRender: true))
        let view = NSHostingView(rootView: root)
        window.contentView = view
        window.orderFrontRegardless()
        renderWindow = window
        RenderCheck.shared.showActions = words.contains("actions")
        RenderCheck.shared.settings = words.contains("settings")
        RenderCheck.shared.day = words.contains("yesterday") ? store.days.last { $0 < dayKey(Date()) } : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let j = self.pendingJump { RenderCheck.shared.jump = j }
            self.pendingJump = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dataDir.appendingPathComponent("render.png"))
            }
            RenderCheck.shared.showActions = false
            RenderCheck.shared.settings = false
            RenderCheck.shared.jump = nil
            RenderCheck.shared.day = nil
            window.orderOut(nil)
            window.contentView = nil
            self.renderWindow = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyData()  // before anything creates the new data folder
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Claude Tasks")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Panel", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Claude Tasks"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // As narrow as the list lays out; any narrower and SwiftUI would centre it and cut off both sides.
        panel.contentMinSize = NSSize(width: 300, height: 260)
        store = Store()
        panel.contentView = NSHostingView(rootView: ContentView(store: store))
        if !panel.setFrameUsingName("ClaudeTasksPanel"), let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 620))
        }
        panel.setFrameAutosaveName("ClaudeTasksPanel")
        panel.orderFrontRegardless()
        renderTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(renderIfAsked),
                                           userInfo: nil, repeats: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
