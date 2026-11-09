import Foundation

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    /// String value or "" (rows from SQLite, JSON payloads).
    func s(_ k: String) -> String { (self[k] as? String) ?? "" }
    /// Optional string, nil when missing or empty.
    func str(_ k: String) -> String? {
        guard let v = self[k] as? String, !v.isEmpty else { return nil }
        return v
    }
    func d(_ k: String) -> Double {
        switch self[k] {
        case let v as Double: return v
        case let v as Int64: return Double(v)
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v) ?? 0
        default: return 0
        }
    }
    func od(_ k: String) -> Double? {
        guard let v = self[k], !(v is NSNull) else { return nil }
        return d(k)
    }
    func i(_ k: String) -> Int64 {
        switch self[k] {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Double: return Int64(v)
        case let v as NSNumber: return v.int64Value
        case let v as String: return Int64(v) ?? 0
        default: return 0
        }
    }
    func oi(_ k: String) -> Int64? {
        guard let v = self[k], !(v is NSNull) else { return nil }
        if let s = v as? String, Int64(s) == nil { return nil }
        return i(k)
    }
    func b(_ k: String) -> Bool {
        if let v = self[k] as? Bool { return v }
        if let v = self[k] as? NSNumber { return v.boolValue }
        if let v = self[k] as? String { return ["true", "1", "yes"].contains(v.lowercased()) }
        return false
    }
}

/// Wrap an optional for SQLite binding.
func nn(_ v: Any?) -> Any { v ?? NSNull() }

func jsonData(_ o: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
}

func jsonString(_ o: Any) -> String { String(decoding: jsonData(o), as: UTF8.self) }

func parseJSON(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) }

func now() -> Double { Date().timeIntervalSince1970 }

extension String {
    func trunc(_ n: Int) -> String {
        count <= n ? self : String(prefix(n)) + "…"
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var oneLine: String {
        replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ").trimmed
    }
}

enum Shell {
    struct Result {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
        var line: String { out.trimmed }
    }

    static var extraPath: String {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    /// Arguments for every `claude -p` call the app makes: no tools, no MCP servers / hooks / CLAUDE.md
    /// (safe mode), nothing saved. Text from agents is untrusted — the model must not be able to act on it.
    static func modelArgs(model: String) -> [String] {
        var a = ["-p", "--tools", "", "--safe-mode", "--no-session-persistence", "--output-format", "text"]
        if !model.isEmpty { a += ["--model", model] }
        return a
    }

    /// Our environment minus a Claude Code session's own variables: if the app was started from a
    /// Claude Code terminal, `claude -p` runs must not count as child sessions of that session.
    static var cleanEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { k, _ in
            !(k == "CLAUDECODE" || k == "CLAUDE_PID" || k == "CLAUDE_EFFORT" || k.hasPrefix("CLAUDE_CODE_"))
        }
    }

    /// Runs a program. Output is read concurrently, so large outputs don't deadlock.
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, input: String? = nil,
                    env: [String: String] = [:], timeout: TimeInterval = 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var environment = cleanEnvironment
        environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
        environment["AGENTBOARD_INTERNAL"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        for (k, v) in env { environment[k] = v }
        p.environment = environment

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return Result(code: -1, out: "", err: error.localizedDescription)
        }
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let writer = inPipe.fileHandleForWriting
        if let input {
            DispatchQueue.global().async {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            }
        } else {
            try? writer.close()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            _ = group.wait(timeout: .now() + 2)
            return Result(code: -2, out: String(decoding: outData, as: UTF8.self), err: "timeout after \(Int(timeout))s")
        }
        _ = group.wait(timeout: .now() + 5)
        return Result(code: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    static func git(_ args: [String], cwd: String, timeout: TimeInterval = 15) -> Result {
        run("/usr/bin/env", ["git"] + args, cwd: cwd, timeout: timeout)
    }

    static func which(_ name: String) -> String? {
        for dir in extraPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let r = run("/bin/zsh", ["-lc", "command -v \(name)"], timeout: 10)
        let path = r.line
        return r.ok && path.hasPrefix("/") ? path : nil
    }
}

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .short
        return f
    }()
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let dayHuman: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()
    static let gitDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func rel(_ ts: Double, now: Date = Date()) -> String {
        if ts <= 0 { return "—" }
        let d = Date(timeIntervalSince1970: ts)
        if now.timeIntervalSince(d) < 10 { return "just now" }
        return relative.localizedString(for: d, relativeTo: now)
    }
    static func time(_ ts: Double) -> String { clock.string(from: Date(timeIntervalSince1970: ts)) }
    static func day(_ ts: Double) -> String { dayKey.string(from: Date(timeIntervalSince1970: ts)) }
}
