import Foundation
import Security

/// Per-install secret for the local server (security audit H2). Loopback is reachable by every process and every
/// user on the Mac, so every request except GET /health must present it.
/// - hooks: the bridge sends `X-AgentBoard-Token` read from a 0600 header file (`curl -H @file`, so the
///   token never shows up in `ps`);
/// - MCP: Claude Code / Codex are registered with `Authorization: Bearer <token>`.
enum Auth {
    static let headerName = "X-AgentBoard-Token"
    static var tokenPath: String { Integrations.baseDir + "/token" }
    /// "X-AgentBoard-Token: <token>" — read by curl in the bridge.
    static var headerFilePath: String { Integrations.baseDir + "/auth-header" }

    private static var cached: String?
    private static let lock = NSLock()

    static var token: String {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let t = loadOrCreate()
        cached = t
        return t
    }

    /// ~/.agentboard holds the token and task prompts: owner only (audit L1).
    static func secureBaseDir() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Integrations.baseDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Integrations.baseDir)
    }

    private static func loadOrCreate() -> String {
        secureBaseDir()
        if let s = try? String(contentsOfFile: tokenPath).trimmed, isWellFormed(s) {
            writePrivate(headerName + ": " + s + "\n", headerFilePath)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)
            return s
        }
        let t = newToken()
        writePrivate(t + "\n", tokenPath)
        writePrivate(headerName + ": " + t + "\n", headerFilePath)
        return t
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }   // SystemRandomNumberGenerator, also a CSPRNG
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isWellFormed(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    /// Created 0600 from the start (no window where the file is world-readable).
    static func writePrivate(_ text: String, _ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        fm.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }

    /// The token presented by a request: `X-AgentBoard-Token: t` or `Authorization: Bearer t`.
    static func presented(_ headers: [String: String]) -> String? {
        if let t = headers[headerName.lowercased()]?.trimmed, !t.isEmpty { return t }
        if let a = headers["authorization"]?.trimmed, a.lowercased().hasPrefix("bearer ") {
            return String(a.dropFirst(7)).trimmed
        }
        return nil
    }

    static func isAuthorized(_ headers: [String: String], token: String = Auth.token) -> Bool {
        guard let p = presented(headers) else { return false }
        return constantTimeEqual(p, token)
    }

    /// Compares without returning early, so response time doesn't leak how much of the token was right.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
