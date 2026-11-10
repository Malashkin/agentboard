import Foundation

/// Finds folders where Claude Code or Codex worked recently but that aren't on the board yet, so the human can add
/// them in one click. Reads only the agents' own session files (~/.claude/projects, ~/.codex/sessions) — no disk-wide
/// scan, no extra macOS permissions. Never adds anything by itself.
enum ProjectDiscovery {
    /// One agent session: where it ran and when it was last written.
    struct Session: Equatable { var tool: String; var cwd: String; var at: Double }

    struct Candidate: Identifiable, Equatable {
        /// The folder that would become the project (git top level, or the main checkout of a worktree).
        var path: String
        var sessions: Int
        var lastAt: Double
        var tools: [String]
        var isGit: Bool
        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        var toolsLabel: String {
            tools.map { $0 == "codex" ? "Codex" : "Claude Code" }.joined(separator: " · ")
        }
    }

    /// What a session folder resolves to.
    struct Resolved: Equatable { var root: String; var commonDir: String; var isGit: Bool }

    /// Already on the board or removed from it (removed ones aren't suggested again).
    struct Known { var path: String; var commonDir: String }

    static let ignoredKey = "ignoredProjectSuggestions"
    static var ignored: Set<String> { Set(UserDefaults.standard.stringArray(forKey: ignoredKey) ?? []) }
    static func ignore(_ path: String) {
        UserDefaults.standard.set(Array(ignored.union([path])).sorted(), forKey: ignoredKey)
    }
    static func clearIgnored() { UserDefaults.standard.removeObject(forKey: ignoredKey) }

    /// Folders that hold many unrelated things, and places no one keeps a project.
    static var defaultExcluded: [String] {
        let home = NSHomeDirectory()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return ["/", home, home + "/Desktop", home + "/Documents", home + "/Downloads"]
            .map { $0 + "=" }   // "=": exact match only
            + [home + "/Library", "/tmp", "/private/tmp", "/private/var/folders", "/var/folders", "/System", "/Volumes/Recovery",
               tmp, AppSettings.worktreeRoot]
    }

    // MARK: - Scan (off the main thread)

    static func scan(days: Int = 60, known: [Known], ignored: Set<String> = ignored,
                     excluded: [String] = defaultExcluded) -> [Candidate] {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return build(sessions(since: since), known: known, ignored: ignored, excluded: excluded, resolve: resolve)
    }

    /// Claude Code transcripts and Codex rollouts written since `since`.
    static func sessions(since: Double) -> [Session] {
        let fm = FileManager.default
        var out: [Session] = []
        let claude = HistoryImporter.claudeRoot
        for d in (try? fm.contentsOfDirectory(atPath: claude)) ?? [] {
            let dir = claude + "/" + d
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".jsonl") {
                let f = dir + "/" + n
                let at = modified(f)
                guard at >= since, let cwd = cwd(of: f, tool: "claude") else { continue }
                out.append(Session(tool: "claude", cwd: cwd, at: at))
            }
        }
        if let e = fm.enumerator(atPath: HistoryImporter.codexRoot) {
            while let n = e.nextObject() as? String {
                guard n.hasSuffix(".jsonl") else { continue }
                let f = HistoryImporter.codexRoot + "/" + n
                let at = modified(f)
                guard at >= since, let cwd = cwd(of: f, tool: "codex") else { continue }
                out.append(Session(tool: "codex", cwd: cwd, at: at))
            }
        }
        return out
    }

    private static func modified(_ path: String) -> Double {
        (((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date) ?? .distantPast)
            .timeIntervalSince1970
    }

    /// A session's folder never changes, so it is read once per file (only the head of the file).
    private static var cwdCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    static func cwd(of file: String, tool: String) -> String? {
        cacheLock.lock()
        if let c = cwdCache[file] { cacheLock.unlock(); return c.isEmpty ? nil : c }
        cacheLock.unlock()
        var found = ""
        if let h = FileHandle(forReadingAtPath: file) {
            let head = (try? h.read(upToCount: 256 << 10)) ?? Data()
            try? h.close()
            found = cwd(inHead: head, tool: tool) ?? ""
        }
        cacheLock.lock(); cwdCache[file] = found; cacheLock.unlock()
        return found.isEmpty ? nil : found
    }

    /// Claude Code puts `cwd` on every message line; Codex puts it in `session_meta` / `turn_context` payloads.
    static func cwd(inHead head: Data, tool: String) -> String? {
        for line in head.split(separator: 0x0A) {
            guard let o = parseJSON(Data(line)) as? JSON else { continue }
            let c = tool == "codex" ? ((o["payload"] as? JSON)?.str("cwd") ?? o.str("cwd")) : o.str("cwd")
            if let c, c.hasPrefix("/") { return c }
        }
        return nil
    }

    /// The project folder for a session folder: git top level (a linked worktree → its main checkout),
    /// otherwise the folder itself. nil when the folder no longer exists.
    static func resolve(_ cwd: String) -> Resolved? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
        let top = Shell.git(["rev-parse", "--show-toplevel"], cwd: path, timeout: 5)
        guard top.ok, !top.line.isEmpty else { return Resolved(root: path, commonDir: "", isGit: false) }
        let common = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: path, timeout: 5)
        var root = top.line
        if common.ok, common.line.hasSuffix("/.git") {
            let main = String(common.line.dropLast("/.git".count))
            if main != root, FileManager.default.fileExists(atPath: main) { root = main }
        }
        return Resolved(root: root, commonDir: common.ok ? common.line : "", isGit: true)
    }

    // MARK: - Pure logic

    static func isExcluded(_ path: String, _ excluded: [String]) -> Bool {
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }   // ~/.config, tool sandboxes
        return excluded.contains { e in
            if e.hasSuffix("=") { return path == String(e.dropLast()) }
            return path == e || path.hasPrefix(e.hasSuffix("/") ? e : e + "/")
        }
    }

    static func build(_ sessions: [Session], known: [Known], ignored: Set<String>, excluded: [String],
                      resolve: (String) -> Resolved?) -> [Candidate] {
        func inside(_ p: String, _ base: String) -> Bool { p == base || p.hasPrefix(base + "/") }
        var resolved: [String: Resolved?] = [:]
        var byRoot: [String: Candidate] = [:]
        for s in sessions {
            if isExcluded(s.cwd, excluded) { continue }
            // Sessions inside a project on the board are tracked already.
            if known.contains(where: { inside(s.cwd, $0.path) }) { continue }
            if resolved[s.cwd] == nil { resolved[s.cwd] = .some(resolve(s.cwd)) }
            guard let r = resolved[s.cwd] ?? nil else { continue }
            if isExcluded(r.root, excluded) || ignored.contains(r.root) { continue }
            if known.contains(where: { inside(r.root, $0.path) || (!r.commonDir.isEmpty && r.commonDir == $0.commonDir) }) {
                continue
            }
            var c = byRoot[r.root] ?? Candidate(path: r.root, sessions: 0, lastAt: 0, tools: [], isGit: r.isGit)
            c.sessions += 1
            c.lastAt = max(c.lastAt, s.at)
            if !c.tools.contains(s.tool) { c.tools = (c.tools + [s.tool]).sorted() }
            byRoot[r.root] = c
        }
        // A plain folder that holds other candidates or projects is a container (~/Desktop/fun), not a project.
        let roots = Array(byRoot.keys) + known.map(\.path)
        let out = byRoot.values.filter { c in
            c.isGit || !roots.contains { $0 != c.path && $0.hasPrefix(c.path + "/") }
        }
        return out.sorted { $0.lastAt != $1.lastAt ? $0.lastAt > $1.lastAt : $0.path < $1.path }
    }
}
