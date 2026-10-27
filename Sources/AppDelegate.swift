// The floating panel, the menu bar icon and the debug triggers.
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var renderTimer: Timer?
    var store: Store!

    @objc func showPanel() { panel.orderFrontRegardless() }
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
    // look without screen-recording permission. A number in the file renders at that height;
    // the word "actions" shows every row's hover buttons, and "settings" the text-size page.
    @objc func renderIfAsked() {
        // A `triage-now` file runs Triage, over every listed task when it says "all".
        let triage = dataDir.appendingPathComponent("triage-now")
        if let words = try? String(contentsOf: triage, encoding: .utf8) {
            try? FileManager.default.removeItem(at: triage)
            store.runJudge(all: words.contains("all"))
        }
        // A `jump-now` file holding a section title acts like clicking that section's count.
        let jump = dataDir.appendingPathComponent("jump-now")
        if let title = try? String(contentsOf: jump, encoding: .utf8) {
            try? FileManager.default.removeItem(at: jump)
            RenderCheck.shared.jump = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trigger = dataDir.appendingPathComponent("render-now")
        guard let request = try? String(contentsOf: trigger, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: trigger)
        let saved = panel.frame
        let words = request.split(whereSeparator: \.isWhitespace)
        if let h = words.compactMap({ Double($0) }).first {
            panel.setFrame(NSRect(x: saved.minX, y: saved.maxY - h, width: saved.width, height: h), display: true)
        }
        RenderCheck.shared.showActions = words.contains("actions")
        if words.contains("settings") { RenderCheck.shared.settings = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let v = self.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dataDir.appendingPathComponent("render.png"))
            }
            RenderCheck.shared.showActions = false
            if words.contains("settings") { RenderCheck.shared.settings = false }
            self.panel.setFrame(saved, display: true)
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

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Claude Tasks"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
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
