import Foundation

/// Backfills a project with work done before AgentBoard was watching it:
/// Claude Code transcripts (~/.claude/projects), Codex rollouts (~/.codex/sessions) and git commits.
/// Writes events with their original timestamps; never notifies, never messages agents.
/// Each session is imported once (table `imported_sessions`); a session that AgentBoard already
/// follows live is imported only up to the moment it was first seen.
enum HistoryImporter {
    struct Result { var sessions = 0; var events = 0; var commits = 0 }

    static var claudeRoot: String {
        (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.claude") + "/projects"
    }
    static var codexRoot: String {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return h + "/sessions" }
        return NSHomeDirectory() + "/.codex/sessions"
    }

    static func ensureSchema(_ core: Core) {
        core.db.exec("CREATE TABLE IF NOT EXISTS imported_sessions(tool TEXT, session_id TEXT, project_id TEXT, imported_at REAL, PRIMARY KEY(tool, session_id));")
        let cols = Set(core.db.query("PRAGMA table_info(imported_sessions)").map { $0.s("name") })
        if !cols.contains("last_at") { core.db.exec("ALTER TABLE imported_sessions ADD COLUMN last_at REAL DEFAULT 0") }
    }

    /// Runs off the main thread; DB work goes through `Core.q`.
    static func run(project p: Project, days: Int = 60) -> Result {
        Core.shared.q.sync { ensureSchema(Core.shared) }
        let horizon = Date().addingTimeInterval(-Double(days) * 86400)
        var r = Result()
        for f in claudeFiles(for: p, since: horizon) { importClaude(f, project: p, into: &r) }
        for f in codexFiles(since: horizon) { importCodex(f, project: p, into: &r) }
        importCommits(project: p, days: days, into: &r)
        if r.events + r.commits > 0 { Core.shared.q.sync { Core.shared.changed() } }
        return r
    }

    // MARK: - Shared

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    static func ts(_ s: String) -> Double? {
        (iso.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date) ?? .distantPast
    }

    private static func lines(_ path: String) -> [JSON] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return data.split(separator: 0x0A).compactMap { parseJSON(Data($0)) as? JSON }
    }

    struct Entry { let at: Double; let kind: String; let title: String; let detail: String; var ref = "" }

    /// One session → one (ended) agent + its events. Returns false when the session was skipped.
    private static func store(tool: String, sessionId: String, cwd: String, branch: String, transcript: String,
                              entries raw: [Entry], project p: Project, into r: inout Result) {
        guard !raw.isEmpty else { return }
        Core.shared.q.sync {
            let core = Core.shared
            let db = core.db!
            var entries = raw.sorted { $0.at < $1.at }
            let agentId: String
            let prev = db.query("SELECT project_id, last_at FROM imported_sessions WHERE tool=? AND session_id=?", [tool, sessionId]).first
            let known = db.query("SELECT * FROM agents WHERE tool=? AND session_id=?", [tool, sessionId]).first.map(Agent.init)
            if let prev {
                // Imported before: append only what the session did since then.
                guard prev.s("project_id") == p.id, let a = known else { return }
                entries = entries.filter { $0.at > prev.d("last_at") }
                guard !entries.isEmpty else { return }
                agentId = a.id
                if a.status == "ended" {
                    db.update("agents", id: a.id, ["last_seen": entries.last!.at, "ended_at": entries.last!.at,
                                                    "last_action": entries.last!.title.trunc(200), "last_action_at": entries.last!.at])
                }
            } else if let live = known {
                // Already followed live: only the part before AgentBoard saw it.
                entries = entries.filter { $0.at < live.startedAt - 1 }
                agentId = live.id
                if let first = entries.first { db.update("agents", id: live.id, ["started_at": first.at]) }
            } else {
                let used = Set(db.query("SELECT name FROM agents WHERE project_id=?", [p.id]).map { $0.s("name") })
                var name = Core.heroNames.first { !used.contains($0) } ?? ""
                if name.isEmpty {
                    var i = 2
                    outer: while true { for n in Core.heroNames where !used.contains("\(n)-\(i)") { name = "\(n)-\(i)"; break outer }; i += 1 }
                }
                var id = tool + "-" + String(sessionId.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                var n = 2
                let base = id
                while !db.query("SELECT 1 FROM agents WHERE id=?", [id]).isEmpty { id = "\(base)\(n)"; n += 1 }
                let top = Shell.git(["rev-parse", "--show-toplevel"], cwd: cwd, timeout: 5)
                let first = entries.first!.at, last = entries.last!.at
                let lastPrompt = entries.last { $0.kind == "prompt" }?.detail ?? ""
                let lastLine = entries.last { $0.kind != "session_start" }?.title ?? ""
                db.query("""
                    INSERT INTO agents(id, project_id, tool, session_id, name, cwd, root, branch, status, last_prompt,
                                       last_action, last_action_at, started_at, last_seen, ended_at, transcript_path)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [id, p.id, tool, sessionId, name, cwd, top.ok ? top.line : cwd, branch, "ended",
                          lastPrompt.trunc(2000), lastLine.trunc(200), last, first, last, last, transcript])
                agentId = id
            }
            guard !entries.isEmpty else { return }
            let name = db.query("SELECT name FROM agents WHERE id=?", [agentId]).first?.s("name") ?? ""
            db.exec("BEGIN")
            for e in entries {
                let title = e.kind == "prompt" ? "\(name): \(e.title)" : e.kind == "turn_done" ? "\(name) завершил ход" : e.title
                db.query("INSERT INTO events(project_id, agent_id, kind, title, detail, client, ref, created_at) VALUES(?,?,?,?,?,?,?,?)",
                         [p.id, agentId, e.kind, title.trunc(300), e.detail.trunc(8000), p.client, e.ref, e.at])
                if e.kind == "action", !e.ref.isEmpty {
                    db.query("""
                        INSERT INTO file_touches(agent_id, project_id, path, count, last_at) VALUES(?,?,?,1,?)
                        ON CONFLICT(agent_id, path) DO UPDATE SET count = count + 1, last_at = max(last_at, excluded.last_at)
                        """, [agentId, p.id, e.ref, e.at])
                }
            }
            db.query("""
                INSERT INTO imported_sessions(tool, session_id, project_id, imported_at, last_at) VALUES(?,?,?,?,?)
                ON CONFLICT(tool, session_id) DO UPDATE SET imported_at=excluded.imported_at, last_at=excluded.last_at
                """, [tool, sessionId, p.id, now(), entries.last!.at])
            if prev != nil { r.sessions -= 1 }
            db.exec("COMMIT")
            r.sessions += 1
            r.events += entries.count
        }
    }

    /// True when the session was imported and its file hasn't grown since.
    private static func alreadyImported(_ tool: String, _ id: String, file: String) -> Bool {
        let last = Core.shared.q.sync {
            Core.shared.db.query("SELECT last_at FROM imported_sessions WHERE tool=? AND session_id=?", [tool, id]).first?.d("last_at")
        }
        guard let last else { return false }
        return modified(file).timeIntervalSince1970 <= last + 5
    }

    private static func inProject(_ cwd: String, _ p: Project) -> Bool {
        cwd == p.path || cwd.hasPrefix(p.path + "/")
    }

    private static func rel(_ path: String, _ p: Project) -> String {
        path.hasPrefix(p.path + "/") ? String(path.dropFirst(p.path.count + 1)) : path
    }

    // MARK: - Claude Code

    /// Claude stores sessions in a folder named after the cwd with "/" and "." replaced by "-".
    private static func claudeFiles(for p: Project, since: Date) -> [String] {
        let fm = FileManager.default
        let key = p.path.map { $0 == "/" || $0 == "." || $0 == "_" ? "-" : String($0) }.joined()
        guard let dirs = try? fm.contentsOfDirectory(atPath: claudeRoot) else { return [] }
        var out: [String] = []
        for d in dirs where d == key || d.hasPrefix(key + "-") || (d.count > 1 && key.hasPrefix(d + "-")) {
            let dir = claudeRoot + "/" + d
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".jsonl") {
                let f = dir + "/" + n
                if modified(f) > since { out.append(f) }
            }
        }
        return out
    }

    private static func userText(_ msg: JSON) -> String? {
        if let s = msg["content"] as? String { return s }
        guard let blocks = msg["content"] as? [JSON] else { return nil }
        if blocks.contains(where: { $0.s("type") == "tool_result" }) { return nil }
        let t = blocks.filter { $0.s("type") == "text" }.map { $0.s("text") }.joined(separator: "\n")
        return t.isEmpty ? nil : t
    }

    private static func isNoise(_ t: String) -> Bool {
        let s = t.trimmed
        return s.isEmpty || s.hasPrefix("<command-") || s.hasPrefix("<local-command") || s.hasPrefix("Caveat:")
            || s.hasPrefix("<system-reminder>") || s.hasPrefix("[Request interrupted") || s.hasPrefix("This session is being continued")
    }

    static func describe(_ tool: String, _ input: JSON, _ p: Project) -> (title: String, detail: String, file: String) {
        func r(_ s: String) -> String { rel(s, p) }
        switch tool {
        case "Bash":
            let cmd = input.s("command")
            return ("$ " + cmd.oneLine.trunc(240), ((input.str("description") ?? "") + "\n" + cmd.trunc(2000)).trimmed, "")
        case "Edit", "MultiEdit": return ("правит \(r(input.s("file_path")))", "", r(input.s("file_path")))
        case "Write": return ("пишет \(r(input.s("file_path")))", "", r(input.s("file_path")))
        case "NotebookEdit": return ("правит \(r(input.s("notebook_path")))", "", r(input.s("notebook_path")))
        case "Read": return ("читает \(r(input.s("file_path")))", "", "")
        case "Grep": return ("ищет «\(input.s("pattern").trunc(80))»\(input.str("path").map { " в \(r($0))" } ?? "")", "", "")
        case "Glob": return ("ищет файлы \(input.s("pattern"))", "", "")
        case "WebFetch": return ("открывает \(input.s("url").trunc(160))", input.s("prompt").trunc(500), "")
        case "WebSearch": return ("ищет в сети: \(input.s("query").trunc(160))", "", "")
        case "Task", "Agent": return ("запускает субагента: \(input.s("description").trunc(160))", input.s("prompt").trunc(2000), "")
        case "TodoWrite":
            let todos = (input["todos"] as? [JSON]) ?? []
            let cur = todos.first { $0.s("status") == "in_progress" }?.s("content") ?? todos.first?.s("content") ?? ""
            return ("план: \(cur.trunc(180))", todos.map { "[\($0.s("status"))] \($0.s("content"))" }.joined(separator: "\n"), "")
        default:
            let args = jsonString(input)
            return ("\(tool.replacingOccurrences(of: "mcp__", with: "")) \(args.oneLine.trunc(140))", args.trunc(1500), "")
        }
    }

    private static func importClaude(_ path: String, project p: Project, into r: inout Result) {
        var sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if alreadyImported("claude", sessionId, file: path) { return }
        let items = lines(path)
        var cwd = "", branch = ""
        var entries: [Entry] = []
        var answer = "", answerAt = 0.0, lastTitle = ""
        var uses = 0, refs = 0
        func flush() {
            if !answer.isEmpty { entries.append(Entry(at: answerAt, kind: "turn_done", title: "", detail: answer.trunc(3000))) }
            answer = ""
        }
        for o in items {
            guard let at = ts(o.s("timestamp")) else { continue }
            if o["isSidechain"] as? Bool == true { continue }
            if let s = o.str("sessionId") { sessionId = s }
            if cwd.isEmpty, let c = o.str("cwd"), !c.isEmpty { cwd = c }  // launch folder; later lines follow `cd`
            if let b = o.str("gitBranch"), !b.isEmpty { branch = b }
            guard let msg = o["message"] as? JSON else { continue }
            switch o.s("type") {
            case "user":
                if o["isMeta"] as? Bool == true { continue }
                guard let t = userText(msg), !isNoise(t) else { continue }
                flush()
                entries.append(Entry(at: at, kind: "prompt", title: t.oneLine.trunc(160), detail: t.trunc(4000)))
            case "assistant":
                for b in (msg["content"] as? [JSON]) ?? [] {
                    if b.s("type") == "text", !b.s("text").trimmed.isEmpty {
                        answer = b.s("text").trimmed; answerAt = at
                    } else if b.s("type") == "tool_use" {
                        let d = describe(b.s("name"), b["input"] as? JSON ?? [:], p)
                        if d.title == lastTitle { continue }
                        lastTitle = d.title
                        uses += 1
                        if jsonString(b["input"] as? JSON ?? [:]).contains(p.path) { refs += 1 }
                        entries.append(Entry(at: at, kind: "action", title: d.title, detail: d.detail, ref: d.file))
                    }
                }
            default: break
            }
        }
        flush()
        // A session started in a parent folder (e.g. ~) counts when it mostly works on this project.
        let fromParent = !cwd.isEmpty && p.path.hasPrefix(cwd == "/" ? "/" : cwd + "/") && refs >= 5 && refs * 4 >= uses
        guard inProject(cwd, p) || fromParent else { return }
        if fromParent { cwd = p.path }
        store(tool: "claude", sessionId: sessionId, cwd: cwd, branch: branch, transcript: path, entries: entries, project: p, into: &r)
    }

    // MARK: - Codex

    private static func codexFiles(since: Date) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: codexRoot) else { return [] }
        var out: [String] = []
        while let n = e.nextObject() as? String {
            guard n.hasSuffix(".jsonl") else { continue }
            let f = codexRoot + "/" + n
            if modified(f) > since { out.append(f) }
        }
        return out
    }

    private static func importCodex(_ path: String, project p: Project, into r: inout Result) {
        var sessionId = String(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.suffix(36))
        if alreadyImported("codex", sessionId, file: path) { return }
        var cwd = "", lastUser = "", answer = ""
        var entries: [Entry] = []
        for o in lines(path) {
            let type = o.s("type")
            let pl = (o["payload"] as? JSON) ?? o
            if type == "session_meta" { if let id = pl.str("id") { sessionId = id }; if let c = pl.str("cwd") { cwd = c }; continue }
            if type == "turn_context", let c = pl.str("cwd") { cwd = c; continue }
            guard let at = ts(o.s("timestamp")) else { continue }
            switch pl.s("type") {
            case "user_message":
                let t = pl.s("message").trimmed
                guard !t.isEmpty, t != lastUser, !t.hasPrefix("<environment_context>"), !t.hasPrefix("<user_instructions>") else { continue }
                lastUser = t
                entries.append(Entry(at: at, kind: "prompt", title: t.oneLine.trunc(160), detail: t.trunc(4000)))
            case "agent_message":
                answer = pl.s("message").trimmed
            case "task_complete", "turn_complete":
                let a = pl.str("last_agent_message") ?? answer
                entries.append(Entry(at: at, kind: "turn_done", title: "", detail: a.trunc(3000)))
                answer = ""
            case "function_call", "local_shell_call", "custom_tool_call":
                var args: JSON = [:]
                if let s = pl.str("arguments"), let j = parseJSON(Data(s.utf8)) as? JSON { args = j }
                if let a = pl["action"] as? JSON { args = a }
                let name = pl.s("name")
                if name == "apply_patch" || pl.s("input").contains("*** Begin Patch") {
                    for (verb, f) in Core.patchFiles(pl.s("input")) {
                        entries.append(Entry(at: at, kind: "action", title: "\(verb) \(rel(f, p))", detail: "", ref: rel(f, p)))
                    }
                } else {
                    let cmd = Core.codexCommand(args)
                    if !cmd.isEmpty {
                        entries.append(Entry(at: at, kind: "action", title: "$ " + cmd.oneLine.trunc(240), detail: cmd.trunc(2000)))
                    } else if !name.isEmpty {
                        let a = jsonString(args)
                        entries.append(Entry(at: at, kind: "action", title: "\(name) \(a.oneLine.trunc(160))", detail: a.trunc(2000)))
                    }
                }
            default: break
            }
        }
        if !answer.isEmpty, let last = entries.last { entries.append(Entry(at: last.at, kind: "turn_done", title: "", detail: answer.trunc(3000))) }
        guard inProject(cwd, p) else { return }
        store(tool: "codex", sessionId: sessionId, cwd: cwd, branch: "", transcript: path, entries: entries, project: p, into: &r)
    }

    // MARK: - Git

    /// Commits from all local branches; each attributed to the agent that ran `git commit` shortly before.
    private static func importCommits(project p: Project, days: Int, into r: inout Result) {
        let sep = "\u{1f}"
        let log = Shell.git(["log", "--all", "--since=\(days).days", "--format=%H\(sep)%h\(sep)%at\(sep)%an\(sep)%s\(sep)%D"], cwd: p.path, timeout: 30)
        guard log.ok else { return }
        let rows = log.out.split(separator: "\n").map { $0.components(separatedBy: sep) }.filter { $0.count >= 5 }
        Core.shared.q.sync {
            let db = Core.shared.db!
            db.exec("BEGIN")
            for c in rows {
                let hash = c[0], short = c[1], at = Double(c[2]) ?? 0, author = c[3], subject = c[4]
                if !db.query("SELECT 1 FROM events WHERE kind='commit' AND ref=?", [hash]).isEmpty { continue }
                let agent = db.query("""
                    SELECT agent_id FROM events WHERE project_id=? AND kind='action' AND title LIKE '$ %git%commit%'
                      AND created_at BETWEEN ? AND ? ORDER BY created_at DESC LIMIT 1
                    """, [p.id, at - 600, at + 5]).first?.str("agent_id")
                let refs = c.count > 5 && !c[5].isEmpty ? "\nВетки: \(c[5])" : ""
                db.query("INSERT INTO events(project_id, agent_id, kind, title, detail, client, ref, created_at) VALUES(?,?,?,?,?,?,?,?)",
                         [p.id, nn(agent), "commit", "\(short) \(subject)".trunc(300), "Автор: \(author)\(refs)", p.client, hash, at])
                r.commits += 1
            }
            db.exec("COMMIT")
        }
    }
}
