// Terminal sessions: transcripts, pending questions, and finding or resuming their Terminal tab.
import SwiftUI
import AppKit

// Where the CLI keeps a session's transcript: its folder, with every character that isn't a
// letter or digit turned into "-", under ~/.claude/projects.
func transcriptURL(cwd: String, cliId: String) -> URL {
    let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    return projectsRoot.appendingPathComponent(folder).appendingPathComponent("\(cliId).jsonl")
}

// What the end of a desktop session's transcript says. `ask`: the question waiting on the user:
// one Claude put mid-turn with AskUserQuestion and that has no answer yet, or one its last turn
// closed on, when the wrap-up asked something (or said it is blocked on the user) and no message
// from the user has come since. `interrupted`: the user stopped the last turn, which
// the session record doesn't show as the turn ending.
struct TranscriptTail {
    var ask: String?
    var interrupted = false
}

func readTail(of url: URL) -> TranscriptTail {
    guard let h = try? FileHandle(forReadingFrom: url) else { return TranscriptTail() }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
    let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    var pending: String?, interrupted = false
    var asking: (id: String, question: String)?  // an AskUserQuestion still waiting for its answer
    for line in tail.split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        let content = (o["message"] as? [String: Any])?["content"]
        if o["type"] as? String == "assistant" {
            for c in content as? [[String: Any]] ?? [] {
                let name = c["name"] as? String ?? ""
                let input = c["input"] as? [String: Any] ?? [:]
                if name.hasSuffix("__wrap_up") {
                    let ask = (input["ask"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    pending = ask ?? ((input["blocked"] as? Bool) == true ? input["recap"] as? String : nil)
                } else if name == "AskUserQuestion", let id = c["id"] as? String,
                          let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String {
                    asking = (id, q)
                }
            }
        } else if o["type"] as? String == "user", (o["isMeta"] as? Bool) != true {
            // The answer to a question comes back as its tool result.
            if let id = asking?.id, (content as? [[String: Any]])?.contains(where: { $0["tool_use_id"] as? String == id }) == true {
                asking = nil
            }
            // A reply typed by the user answers it; tool results and system notices don't.
            let text = (content as? String)
                ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
            if let text, !text.hasPrefix("<") {
                pending = nil
                asking = nil
                interrupted = text.hasPrefix("[Request interrupted")
            }
        }
    }
    return TranscriptTail(ask: asking?.question ?? pending, interrupted: interrupted)
}

// PRs a shell command looks at with `gh pr <subcommand> <n or URL>`, with `-R/--repo
// owner/repo` when given. A number alone comes back as "#12", meaning the session's own repo.
func prCommandRefs(_ command: String, _ subcommands: Set<String>) -> [String] {
    var refs: [String] = []
    for segment in command.components(separatedBy: CharacterSet(charactersIn: ";&|\n")) {
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let gh = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "gh" }),
              words.count > gh + 3, words[gh + 1] == "pr", subcommands.contains(words[gh + 2])
        else { continue }
        let args = Array(words[(gh + 3)...]).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        var repo: String?, target: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-R" || a == "--repo" {
                repo = i + 1 < args.count ? args[i + 1] : nil
                i += 2
                continue
            }
            if a.hasPrefix("--repo=") { repo = String(a.dropFirst("--repo=".count)) }
            if target == nil, (a.contains("github.com/") && a.contains("/pull/")) || Int(a) != nil { target = a }
            i += 1
        }
        if let t = target { refs.append(Int(t) != nil ? (repo ?? "") + "#" + t : t) }
    }
    return refs
}

// PRs a shell command reads through the GitHub API: `gh api repos/<owner>/<repo>/pulls/<n>…`.
func prAPIRefs(_ command: String) -> [String] {
    captures(#"\bgh\s+api\s+['"]?/?repos/([\w.-]+/[\w.-]+)/pulls/(\d+)"#, in: command).map { $0[1] + "#" + $0[2] }
}

// Branches a shell command works on: `git checkout|switch [-b|-c] <branch>` and the branch in
// `git push <remote> <branch>`. Sessions sharing a folder share its current branch, so only a
// branch a session moved to or pushed is its own.
func branchCommandRefs(_ command: String) -> [String] {
    var branches: [String] = []
    for segment in command.components(separatedBy: CharacterSet(charactersIn: ";&|\n")) {
        let words = segment.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        guard let git = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "git" }), words.count > git + 2
        else { continue }
        let args = words[(git + 2)...].filter { !$0.hasPrefix("-") }
        switch words[git + 1] {
        case "checkout", "switch":
            // `git checkout -- <file>` restores files, it doesn't switch.
            if !words.contains("--"), let b = args.first, b != "." { branches.append(b) }
        case "push":
            if args.count >= 2 {
                let ref = args[args.index(after: args.startIndex)]
                let b = ref.split(separator: ":").last.map(String.init) ?? ref
                branches.append(b.replacingOccurrences(of: "refs/heads/", with: ""))
            }
        default:
            break
        }
    }
    return branches
}

// The shell commands in an assistant transcript entry.
func commands(inEntry o: [String: Any]) -> [String] {
    guard o["type"] as? String == "assistant" else { return [] }
    return ((o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).compactMap { c -> String? in
        guard c["type"] as? String == "tool_use" else { return nil }
        return (c["input"] as? [String: Any])?["command"] as? String
    }
}

// What a transcript says about the work, kept up as it grows: only lines added since the last
// look are read, since transcripts only ever get appended to.
struct TranscriptFacts {
    var offset: UInt64 = 0
    var branch: String?            // the folder's branch, as last recorded
    var branches: [String] = []    // branches the session itself checked out or pushed, oldest first
    var reviewRefs: [String] = []  // PRs it checked out or reviewed with gh
    var diffRefs: [String] = []    // PRs it only diffed or viewed: a reviewer does, but so does the author
    var pushed = false             // it pushed a branch or opened a PR: its own work

    mutating func add(_ commands: [String]) {
        for c in commands {
            for r in prCommandRefs(c, ["checkout", "review"]) where !reviewRefs.contains(r) { reviewRefs.append(r) }
            for r in prCommandRefs(c, ["diff", "view"]) + prAPIRefs(c) where !diffRefs.contains(r) { diffRefs.append(r) }
            for b in branchCommandRefs(c) {
                branches.removeAll { $0 == b }
                branches.append(b)
            }
            if c.range(of: #"\bgit\s+push\b|\bgh\s+pr\s+create\b"#, options: .regularExpression) != nil { pushed = true }
        }
    }
}

func scanTranscript(_ url: URL, from facts: TranscriptFacts) -> TranscriptFacts {
    guard let h = try? FileHandle(forReadingFrom: url) else { return facts }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    var f = size < facts.offset ? TranscriptFacts() : facts  // rewritten: start over
    try? h.seek(toOffset: f.offset)
    // A few megabytes at a time, whole lines only: some transcripts run to tens of megabytes.
    // Each block's temporary objects are freed before the next, or a first pass over every
    // transcript would hold hundreds of megabytes at once.
    var carry = Data()
    var more = true
    while more {
        autoreleasepool {
            guard let block = try? h.read(upToCount: 4 << 20), !block.isEmpty else { more = false; return }
            let data = carry + block
            guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { carry = data; return }
            let chunk = String(decoding: data[...end], as: UTF8.self)
            f.offset += UInt64(end + 1)
            carry = Data(data[(end + 1)...])
            if let r = chunk.range(of: #""gitBranch":"([^"]+)""#, options: [.regularExpression, .backwards]) {
                f.branch = String(chunk[r].dropFirst(#""gitBranch":""#.count).dropLast())
            }
            for line in chunk.split(separator: "\n") where line.contains("\"tool_use\"") && (line.contains("gh pr ") || line.contains("git ")) {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                f.add(commands(inEntry: o))
            }
        }
    }
    return f
}

// What a session did on one day, from its transcript: the recap Claude wrote at the end of each
// turn (Claude app sessions close every turn with one), and the prompts the user typed (all a
// terminal session has to go on). Each at most 12, the first 2 and the last 10: how the day began
// and where it got to. Also how long it was worked on that day, in minutes: the time between
// its entries, leaving out any gap over 10 minutes as time away. A forked session's transcript
// starts with a copy of its parent's, still under the parent's id; only its own entries count.
func dayTrail(_ url: URL, from start: Date, to end: Date) -> (recaps: [String], prompts: [String], minutes: Int) {
    guard let h = try? FileHandle(forReadingFrom: url) else { return ([], [], 0) }
    defer { try? h.close() }
    let precise = ISO8601DateFormatter()
    precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    var recaps: [String] = [], prompts: [String] = []
    var stamps: [Date] = []
    let own = "\"sessionId\":\"" + url.deletingPathExtension().lastPathComponent + "\""
    var carry = Data()
    var more = true
    while more {
        autoreleasepool {
            guard let block = try? h.read(upToCount: 4 << 20), !block.isEmpty else { more = false; return }
            let data = carry + block
            guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { carry = data; return }
            carry = Data(data[(last + 1)...])
            for line in String(decoding: data[...last], as: UTF8.self).split(separator: "\n")
            where !line.contains("\"sessionId\":\"") || line.contains(own) {
                // Every entry's time, read without parsing the whole line.
                if let r = line.range(of: "\"timestamp\":\""),
                   let close = line[r.upperBound...].firstIndex(of: "\""),
                   let at = precise.date(from: String(line[r.upperBound..<close])), at >= start, at < end {
                    stamps.append(at)
                }
                guard line.contains("__wrap_up") || line.contains("\"type\":\"user\"") else { continue }
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let stamp = o["timestamp"] as? String, let at = precise.date(from: stamp) ?? plain.date(from: stamp),
                      at >= start, at < end else { continue }
                let content = (o["message"] as? [String: Any])?["content"]
                if o["type"] as? String == "assistant" {
                    for c in content as? [[String: Any]] ?? [] where (c["name"] as? String)?.hasSuffix("__wrap_up") == true {
                        if let r = (c["input"] as? [String: Any])?["recap"] as? String, !r.isEmpty { recaps.append(r) }
                    }
                } else if o["type"] as? String == "user", (o["isMeta"] as? Bool) != true {
                    // Typed text only: tool results and command wrappers aren't the user asking.
                    let text = (content as? String)
                        ?? (content as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                            .joined(separator: " ")
                    if let text, !text.isEmpty, !text.hasPrefix("<") { prompts.append(String(text.prefix(300))) }
                }
            }
        }
    }
    func keep(_ a: [String]) -> [String] { a.count <= 12 ? a : Array(a.prefix(2) + a.suffix(10)) }
    stamps.sort()
    let worked = zip(stamps, stamps.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 <= 600 }.reduce(0, +)
    return (keep(recaps), keep(prompts), Int(worked / 60))
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
    var facts = TranscriptFacts()
    var turnOpen = false  // a prompt typed since the last turn ended
    func tag(_ name: String, _ s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>"), a.upperBound <= b.lowerBound else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    for line in text.split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if cwd == nil { cwd = o["cwd"] as? String }
        if let b = o["gitBranch"] as? String, !b.isEmpty { branch = b }
        facts.add(commands(inEntry: o))
        switch o["type"] as? String {
        case "custom-title": title = o["customTitle"] as? String ?? title
        case "last-prompt": lastPrompt = o["lastPrompt"] as? String ?? lastPrompt
        case "system" where o["subtype"] as? String == "turn_duration": turnOpen = false  // written as each turn ends
        case "user":
            // Typed text opens a turn, unless it's the note an interrupt leaves; tool results,
            // notices and command wrappers don't.
            if (o["isMeta"] as? Bool) != true {
                let content = (o["message"] as? [String: Any])?["content"]
                let text = (content as? String)
                    ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
                if let text, !text.hasPrefix("<") { turnOpen = !text.hasPrefix("[Request interrupted") }
            }
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
    guard let cwd = cwd.map(native) else { return nil }
    let clip = { (s: String) in s.count > 60 ? String(s.prefix(60)) + "…" : s }
    let uuid = native(url.deletingPathExtension().lastPathComponent)
    return Session(
        id: "cli_" + uuid, cliId: uuid,
        title: title ?? (first ?? firstCommand).map(clip) ?? "(terminal session)",
        cwd: cwd, runCwd: cwd, lastActivity: Date(timeIntervalSince1970: mtime),
        status: nil,
        detail: (lastPrompt ?? first).map { "Last prompt: " + clip($0) },
        needs: nil, scheduledTaskId: nil, prs: [], archived: false, deleted: false,
        branch: branch, startedAt: created, gitBranch: branch, workBranches: facts.branches,
        reviewRefs: facts.reviewRefs, diffRefs: facts.diffRefs, pushed: facts.pushed, turnOpen: turnOpen)
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

// The ttys of Terminal.app tabs sitting at a shell prompt, front window first. Empty when
// Terminal isn't running, so asking never launches it.
func idleTerminalTTYs() -> [String] {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else { return [] }
    let script = """
    set out to ""
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if not busy of t then set out to out & (tty of t) & linefeed
            end repeat
        end repeat
    end tell
    return out
    """
    var err: NSDictionary?
    let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { log("listing tabs failed: \(err)") }
    return (r?.stringValue ?? "").split(separator: "\n").map(String.init)
}

// Of those ttys, the first whose shell is in this folder.
func ttyInFolder(_ ttys: [String], cwd: String) -> String? {
    guard !ttys.isEmpty else { return nil }
    let shells: Set = ["zsh", "bash", "sh", "fish", "tcsh", "ksh"]
    // The shell in the foreground of each tty: the process waiting at the prompt.
    var shellOn: [String: String] = [:]  // pid -> tty
    for line in shell("/bin/ps", ["-axo", "pid=,tty=,stat=,comm="]).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, parts[2].contains("+") else { continue }
        let tty = "/dev/" + parts[1]
        // ps pads the columns, and a login shell's name starts with "-".
        let name = (parts[3].trimmingCharacters(in: CharacterSet.whitespaces.union(["-"])) as NSString).lastPathComponent
        if ttys.contains(tty), shells.contains(name) { shellOn[String(parts[0])] = tty }
    }
    guard !shellOn.isEmpty else { return nil }
    // lsof prints "p<pid>" then "n<folder>" for each.
    var folderOf: [String: String] = [:]  // tty -> folder
    var pid = ""
    for line in shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", shellOn.keys.joined(separator: ",")])
        .split(separator: "\n") {
        if line.hasPrefix("p") { pid = String(line.dropFirst()) }
        if line.hasPrefix("n"), let tty = shellOn[pid] { folderOf[tty] = String(line.dropFirst()) }
    }
    let want = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
    return ttys.first { folderOf[$0].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == want }
}

// Resumes the session in the Terminal tab on this tty, else in a new tab.
func resumeInTerminal(cwd: String, uuid: String, tty: String? = nil) {
    let cmd = "cd \(shellQuote(cwd)) && claude --resume \(uuid)"
    let reuse = tty.map { tty in """
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is \(appleScriptString(tty)) and not busy of t then
                    do script \(appleScriptString(cmd)) in t
                    set selected of t to true
                    set index of w to 1
                    activate
                    return
                end if
            end repeat
        end repeat
    """ } ?? ""
    let script = """
    tell application "Terminal"
    \(reuse)
        do script \(appleScriptString(cmd))
        activate
    end tell
    """
    var err: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { log("resume failed: \(err)") }
}
