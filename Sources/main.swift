// Lookout
// A floating, always-on-top panel listing Claude Code sessions as tasks: desktop app sessions,
// read-only from the app's own session files, and terminal `claude` sessions, read from their
// transcripts. Click a row to jump to the session.
import SwiftUI
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)  // in the Dock: click it to bring the panel back
app.run()
