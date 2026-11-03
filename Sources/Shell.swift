// Running external tools, and the app log.
import SwiftUI
import AppKit

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func run(_ path: String, _ args: [String], stdin: String? = nil, stdout: FileHandle? = nil) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.currentDirectoryURL = dataDir
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = toolPATH
    p.environment = env
    let out = Pipe()
    p.standardOutput = stdout ?? out
    p.standardError = FileHandle.nullDevice
    let input = Pipe()
    if stdin != nil { p.standardInput = input }
    do { try p.run() } catch { return nil }
    if let s = stdin {
        input.fileHandleForWriting.write(s.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
    }
    let data = stdout == nil ? out.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

// Runs a tool and returns what it printed and its error text, to tell why a lookup failed.
// The error text is read alongside, so a tool that writes a lot of it can't stall on a full pipe.
func runReporting(_ path: String, _ args: [String]) -> (out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = toolPATH
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    guard (try? p.run()) != nil else { return ("", "could not start \(path)") }
    var errData = Data()
    let reading = DispatchGroup()
    reading.enter()
    DispatchQueue.global(qos: .utility).async { errData = err.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    reading.wait()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

// Why a lookup came back empty. `missing`: GitHub or Jira says there's no such item, or none
// the user may see, which won't change soon. Anything else (offline, just woken from sleep,
// signed out, a server error) may pass by the next refresh.
enum LookupFailure {
    case missing, passing
    init(_ err: String) {
        self = err.contains("Could not resolve to a") || err.contains("does not exist or you do not have permission")
            ? .missing : .passing
    }
}

// An error's first line, for the log.
func firstLine(_ err: String) -> String {
    err.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "no output"
}

func log(_ line: String) {
    let url = dataDir.appendingPathComponent("log.txt")
    let entry = "\(Date()) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(entry.data(using: .utf8)!); try? h.close()
    } else {
        try? entry.write(to: url, atomically: true, encoding: .utf8)
    }
}
