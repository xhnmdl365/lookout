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

func log(_ line: String) {
    let url = dataDir.appendingPathComponent("log.txt")
    let entry = "\(Date()) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(entry.data(using: .utf8)!); try? h.close()
    } else {
        try? entry.write(to: url, atomically: true, encoding: .utf8)
    }
}
