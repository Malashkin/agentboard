import Foundation

/// Follows Codex session logs (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) and turns every
/// prompt, shell command, patch, tool call and answer into AgentBoard activity.
/// Codex has no per-action hooks, so its own log is the source of truth.
final class CodexWatcher {
    static let shared = CodexWatcher()
    private let queue = DispatchQueue(label: "agentboard.codex")
    private var timer: DispatchSourceTimer?

    struct FileState {
        var offset: UInt64
        var sessionId: String
        var cwd: String
        var lastUser = ""
        var lastAnswer = ""
    }
    private var files: [String: FileState] = [:]
    /// Session ids whose logs are being followed (so `notify` doesn't duplicate events).
    private(set) var watchedSessions = Set<String>()
    private let lock = NSLock()

    var root: String {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return h + "/sessions" }
        return NSHomeDirectory() + "/.codex/sessions"
    }

    func isWatched(_ session: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return watchedSessions.contains(session)
    }

    func start(interval: Double = 2) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: interval)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    private func candidateFiles() -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        let cal = Calendar.current
        var out: [String] = []
        // Today and yesterday (a session started late keeps writing into yesterday's folder).
        for back in 0...1 {
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = String(format: "%@/%04d/%02d/%02d", root, c.year!, c.month!, c.day!)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".jsonl") { out.append(dir + "/" + n) }
        }
        // Flat layout of older Codex versions.
        if let names = try? fm.contentsOfDirectory(atPath: root) {
            for n in names where n.hasSuffix(".jsonl") { out.append(root + "/" + n) }
        }
        let horizon = Date().addingTimeInterval(-36 * 3600)
        return out.filter {
            ((try? fm.attributesOfItem(atPath: $0)[.modificationDate]) as? Date ?? .distantPast) > horizon
        }
    }

    private func scan() {
        for path in candidateFiles() { follow(path) }
    }

    private func follow(_ path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        var st = files[path] ?? FileState(offset: savedOffset(path), sessionId: "", cwd: "")
        if size < st.offset { st.offset = 0 } // rotated / rewritten
        if st.sessionId.isEmpty { readHeader(path, &st) }
        guard size > st.offset, let fh = FileHandle(forReadingAtPath: path) else { files[path] = st; return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: st.offset)
        let data = (try? fh.read(upToCount: Int(min(size - st.offset, 8_000_000)))) ?? Data()
        // Only complete lines; the rest is read next time.
        guard let lastNL = data.lastIndex(of: 0x0A) else { files[path] = st; return }
        let chunk = data[data.startIndex...lastNL]
        st.offset += UInt64(chunk.count)
        var items: [JSON] = []
        for line in chunk.split(separator: 0x0A) {
            if let obj = parseJSON(Data(line)) as? JSON { items.append(obj) }
        }
        if !st.sessionId.isEmpty {
            lock.lock(); watchedSessions.insert(st.sessionId); lock.unlock()
        }
        let fileState = st
        let result: FileState = Core.shared.q.sync {
            var s = fileState
            for item in items { Core.shared.handleCodexLog(item, state: &s) }
            Core.shared.db.query("INSERT INTO codex_offsets(path, offset) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET offset=excluded.offset",
                                 [path, Int64(s.offset)])
            if !items.isEmpty { Core.shared.changed() }
            return s
        }
        files[path] = result
    }

    /// Session id and cwd from the first lines, even when resuming from a saved offset.
    private func readHeader(_ path: String, _ st: inout FileState) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 200_000)) ?? Data()
        for line in data.split(separator: 0x0A).prefix(40) {
            guard let obj = parseJSON(Data(line)) as? JSON else { continue }
            let p = (obj["payload"] as? JSON) ?? obj
            let type = obj.s("type")
            if type == "session_meta" || (type.isEmpty && obj["id"] != nil && obj["timestamp"] != nil) {
                if st.sessionId.isEmpty { st.sessionId = p.str("id") ?? "" }
                if st.cwd.isEmpty { st.cwd = p.s("cwd") }
            }
            if type == "turn_context", st.cwd.isEmpty { st.cwd = p.s("cwd") }
            if !st.sessionId.isEmpty && !st.cwd.isEmpty { break }
        }
        if st.sessionId.isEmpty {
            // rollout-2026-11-07T10-00-00-<uuid>.jsonl
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            st.sessionId = String(name.suffix(36))
        }
    }

    private func savedOffset(_ path: String) -> UInt64 {
        Core.shared.q.sync {
            UInt64(Core.shared.db.query("SELECT offset FROM codex_offsets WHERE path=?", [path]).first?.i("offset") ?? 0)
        }
    }
}

extension Core {
    /// Commands come as ["bash","-lc","…"], a plain string, or {"cmd": "…"}.
    static func codexCommand(_ args: JSON) -> String {
        if let arr = args["command"] as? [String] {
            if arr.count >= 3, ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"].contains(arr[0]), arr[1].hasPrefix("-") {
                return arr.last ?? ""
            }
            return arr.joined(separator: " ")
        }
        return args.str("command") ?? args.str("cmd") ?? ""
    }

    static func patchFiles(_ patch: String) -> [(verb: String, path: String)] {
        var out: [(String, String)] = []
        for line in patch.split(separator: "\n") {
            for (prefix, verb) in [("*** Update File: ", "правит"), ("*** Add File: ", "создаёт"), ("*** Delete File: ", "удаляет")]
            where line.hasPrefix(prefix) {
                out.append((verb, String(line.dropFirst(prefix.count)).trimmed))
            }
        }
        return out
    }

    func handleCodexLog(_ obj: JSON, state st: inout CodexWatcher.FileState) {
        let type = obj.s("type")
        let p = (obj["payload"] as? JSON) ?? obj
        if type == "session_meta" {
            if let id = p.str("id") { st.sessionId = id }
            if let cwd = p.str("cwd") { st.cwd = cwd }
            return
        }
        if type == "turn_context", let cwd = p.str("cwd") { st.cwd = cwd; return }
        guard !st.sessionId.isEmpty, let project = projectFor(cwd: st.cwd) else { return }

        let kind = p.s("type")
        func agent() -> Agent { touchAgent(tool: "codex", sessionId: st.sessionId, project: project, cwd: st.cwd, transcript: nil, revive: true) }

        switch (type, kind) {
        case ("event_msg", "user_message"), ("", "user_message"):
            let text = p.s("message").trimmed
            guard !text.isEmpty, text != st.lastUser else { return }
            st.lastUser = text
            let a = agent()
            setAgent(a.id, ["status": "working", "last_prompt": text.trunc(2000), "last_action": "получил запрос"])
            addEvent(project: project.id, agent: a.id, kind: "prompt", title: "\(a.name): \(text.oneLine.trunc(160))", detail: text.trunc(4000))

        case ("event_msg", "agent_message"):
            let text = p.s("message").trimmed
            guard !text.isEmpty else { return }
            st.lastAnswer = text
            setAgent(agent().id, ["last_action": "пишет: " + text.oneLine.trunc(160)])

        case ("event_msg", "task_complete"), ("event_msg", "turn_complete"):
            let a = agent()
            let answer = p.str("last_agent_message") ?? st.lastAnswer
            setAgent(a.id, ["status": "idle", "last_action": answer.isEmpty ? "ход завершён" : "ответил: " + answer.oneLine.trunc(160)])
            addEvent(project: project.id, agent: a.id, kind: "turn_done", title: "\(a.name) завершил ход", detail: answer.trunc(3000))
            st.lastAnswer = ""

        case ("response_item", "function_call"), ("", "function_call"),
             ("response_item", "custom_tool_call"), ("", "custom_tool_call"),
             ("response_item", "local_shell_call"), ("", "local_shell_call"):
            let a = agent()
            let name = p.s("name")
            var args: JSON = [:]
            if let s = p.str("arguments"), let j = parseJSON(Data(s.utf8)) as? JSON { args = j }
            if let action = p["action"] as? JSON { args = action }
            let input = p.s("input")

            if kind == "local_shell_call" || ["shell", "exec_command", "container.exec", "local_shell", "unified_exec"].contains(name) {
                let cmd = Self.codexCommand(args)
                guard !cmd.isEmpty else { return }
                setAgent(a.id, ["status": "working", "last_action": "$ " + cmd.oneLine.trunc(200)])
                addAction(agent: a, title: "$ " + cmd.oneLine.trunc(240), detail: cmd.trunc(2000))
                if Self.isGitCommit(cmd) {
                    addEvent(project: project.id, agent: a.id, kind: "commit_request", title: "\(a.name) коммитит (Codex)", detail: cmd)
                    if AppSettings.commitMode != .off {
                        notify?("\(a.name) коммитит · \(project.name)", cmd.oneLine.trunc(200))
                    }
                } else if Self.isGitPush(cmd) {
                    addEvent(project: project.id, agent: a.id, kind: "push", title: "\(a.name): git push", detail: cmd)
                }
                // apply_patch invoked through the shell
                if cmd.contains("*** Begin Patch") { recordPatch(cmd, agent: a, project: project) }
            } else if name == "apply_patch" {
                recordPatch(input.isEmpty ? (args.str("input") ?? args.s("patch")) : input, agent: a, project: project)
            } else if name == "update_plan" {
                let steps = (args["plan"] as? [JSON])?.map { "[\($0.s("status"))] \($0.s("step"))" } ?? []
                setAgent(a.id, ["status": "working", "last_action": "обновил план"])
                addAction(agent: a, title: "план: " + (steps.first { $0.hasPrefix("[in_progress]") } ?? steps.first ?? "").trunc(200),
                          detail: steps.joined(separator: "\n"))
            } else {
                let short = name.isEmpty ? "tool" : name
                let argText = args.isEmpty ? input : jsonString(args)
                setAgent(a.id, ["status": "working", "last_action": "вызывает \(short)"])
                addAction(agent: a, title: "\(short) \(argText.oneLine.trunc(160))", detail: argText.trunc(2000))
            }

        case ("response_item", "web_search_call"):
            let a = agent()
            let q = ((p["action"] as? JSON)?.s("query")) ?? ""
            setAgent(a.id, ["status": "working", "last_action": "ищет в сети: \(q.trunc(120))"])
            addAction(agent: a, title: "веб-поиск: \(q.trunc(200))", detail: "")

        default:
            break
        }
    }

    private func recordPatch(_ patch: String, agent a: Agent, project: Project) {
        for (verb, path) in Self.patchFiles(patch) {
            let rel = relativePath(path, agent: a, project: project)
            touchFile(agent: a, path: rel)
            setAgent(a.id, ["status": "working", "last_action": "\(verb) \(rel)"])
            addAction(agent: a, title: "\(verb) \(rel)", detail: "")
            let others = AppSettings.conflictWarnings ? othersTouching(path: rel, project: project.id, except: a.id) : []
            if !others.isEmpty {
                let names = others.map { $0.name }.joined(separator: ", ")
                addEvent(project: project.id, agent: a.id, kind: "conflict",
                         title: "\(a.name) правит \(rel), который недавно менял(и) \(names)", ref: rel)
                if AppSettings.notifyConflicts {
                    notify?("Возможный конфликт · \(project.name)", "\(a.name) правит \(rel) — его недавно менял(и) \(names)")
                }
                // Codex has no hook to warn it directly; it learns on its next agentboard call.
                sendMessage(project: project.id, to: a.id, from: nil,
                            text: "Внимание: файл \(rel) недавно правил(и) \(names). Не затирай их изменения; согласуй через send_message.")
            }
        }
    }
}
