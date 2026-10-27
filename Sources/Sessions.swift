// Terminal sessions: transcripts, pending questions, and finding or resuming their Terminal tab.
import SwiftUI
import AppKit

// Where the CLI keeps a session's transcript: its folder, with every character that isn't a
// letter or digit turned into "-", under ~/.claude/projects.
func transcriptURL(cwd: String, cliId: String) -> URL {
    let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    return projectsRoot.appendingPathComponent(folder).appendingPathComponent("\(cliId).jsonl")
}

// The question a session's last turn left open: its closing wrap-up asked something (or said it
// is blocked on the user), and no message from the user has come since. Read from the end of the
// transcript only.
func pendingQuestion(in url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
    let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    var pending: String?
    for line in tail.split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        let content = (o["message"] as? [String: Any])?["content"]
        if o["type"] as? String == "assistant" {
            for c in content as? [[String: Any]] ?? [] where (c["name"] as? String)?.hasSuffix("__wrap_up") == true {
                let input = c["input"] as? [String: Any] ?? [:]
                let ask = (input["ask"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                pending = ask ?? ((input["blocked"] as? Bool) == true ? input["recap"] as? String : nil)
            }
        } else if o["type"] as? String == "user", (o["isMeta"] as? Bool) != true {
            // A reply typed by the user answers it; tool results and system notices don't.
            let typed = (content as? String).map { !$0.hasPrefix("<") }
                ?? (content as? [[String: Any]])?.contains { $0["type"] as? String == "text" } ?? false
            if typed { pending = nil }
        }
    }
    return pending
}

// Who wrote a transcript, from its first lines: "cli" is an interactive terminal run,
// "claude-desktop" the desktop app. Desktop transcripts share the folder and are skipped.
func transcriptEntrypoint(_ url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let head = String(decoding: h.readData(ofLength: 65536), as: UTF8.self)
    for line in head.split(separator: "\n") {
        if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
           let e = o["entrypoint"] as? String { return e }
    }
    return nil
}

// A terminal session read from its whole transcript.
func parseTerminalSession(_ url: URL, mtime: Double, created: Date?) -> Session? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var title: String?, first: String?, firstCommand: String?, lastPrompt: String?, cwd: String?, branch: String?
    func tag(_ name: String, _ s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>"), a.upperBound <= b.lowerBound else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    for line in text.split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if cwd == nil { cwd = o["cwd"] as? String }
        if let b = o["gitBranch"] as? String, !b.isEmpty { branch = b }
        switch o["type"] as? String {
        case "custom-title": title = o["customTitle"] as? String ?? title
        case "last-prompt": lastPrompt = o["lastPrompt"] as? String ?? lastPrompt
        case "user":
            // The first thing the user typed; skip command wrappers and tool results.
            guard (o["isMeta"] as? Bool) != true,
                  let c = (o["message"] as? [String: Any])?["content"] as? String else { break }
            if first == nil, !c.hasPrefix("<") { first = c }
            if firstCommand == nil, let name = tag("command-name", c) {
                firstCommand = [name, tag("command-args", c) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            }
        default: break
        }
    }
    guard let cwd else { return nil }
    let clip = { (s: String) in s.count > 60 ? String(s.prefix(60)) + "…" : s }
    let uuid = url.deletingPathExtension().lastPathComponent
    return Session(
        id: "cli_" + uuid, cliId: uuid,
        title: title ?? (first ?? firstCommand).map(clip) ?? "(terminal session)",
        cwd: cwd, runCwd: cwd, lastActivity: Date(timeIntervalSince1970: mtime),
        status: nil,
        detail: (lastPrompt ?? first).map { "Last prompt: " + clip($0) },
        needs: nil, scheduledTaskId: nil, prs: [], archived: false, deleted: false,
        branch: branch, startedAt: created)
}

// How long a session has run, start to last activity: "45m", "3h 20m", "2d 4h".
func span(_ seconds: TimeInterval) -> String {
    let minutes = max(Int(seconds / 60), 1)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
    return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
}

// The tty of a terminal `claude` process running this session, if any. A process started
// with `--resume <id>` names it; a fresh one is matched by working directory, if this is
// the newest terminal session there.
func runningTTY(for s: Session, newestInCwd: Bool) -> String? {
    guard let uuid = s.cliId else { return nil }
    for line in shell("/bin/ps", ["-axo", "pid=,tty=,args="]).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[1] != "??",
              let exe = parts[2].split(separator: " ").first, (exe as NSString).lastPathComponent == "claude"
        else { continue }
        let tty = "/dev/" + parts[1]
        if parts[2].contains(uuid) { return tty }
        guard newestInCwd, !parts[2].contains("--resume"), !parts[2].contains(" -r ") else { continue }
        let cwd = shell("/usr/sbin/lsof", ["-a", "-p", String(parts[0]), "-d", "cwd", "-Fn"])
            .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        if cwd == s.runCwd { return tty }
    }
    return nil
}

func appleScriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// Brings the Terminal.app tab on this tty to the front; false if no tab has it.
func focusTerminalTab(_ tty: String) -> Bool {
    let script = """
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is \(appleScriptString(tty)) then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
    end tell
    return false
    """
    var err: NSDictionary?
    let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { log("focus tab failed: \(err)") }
    return r?.booleanValue ?? false
}

func resumeInTerminal(cwd: String, uuid: String) {
    let cmd = "cd \(shellQuote(cwd)) && claude --resume \(uuid)"
    let script = """
    tell application "Terminal"
        do script \(appleScriptString(cmd))
        activate
    end tell
    """
    var err: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { log("resume failed: \(err)") }
}
