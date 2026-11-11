import Darwin
import Foundation

// MARK: - File reservations
//
// An agent leases files or globs (repo-relative) for a while before editing them. Others are told
// (or stopped) when they try to edit them, and a git pre-commit hook refuses commits by other
// agents that touch reserved files. Leases expire on their own, end with the session, and the
// human can drop any of them from the app.

extension Core {
    func activeReservations(project: String?) -> [Reservation] {
        var sql = """
            SELECT r.* FROM reservations r JOIN agents a ON a.id = r.agent_id
            WHERE r.released_at IS NULL AND r.expires_at > ? AND a.status != 'ended'
            """
        var args: [Any] = [now()]
        if let project { sql += " AND r.project_id = ?"; args.append(project) }
        return db.query(sql + " ORDER BY r.created_at", args).map(Reservation.init)
    }

    static func normalizePattern(_ raw: String, agent: Agent?, project: Project?) -> String {
        var p = raw.trimmed
        if p.hasPrefix("~/") { p = NSHomeDirectory() + p.dropFirst(1) }
        for base in [agent?.root, project?.path, agent?.cwd].compactMap({ $0 }) where !base.isEmpty {
            if p.hasPrefix(base + "/") { p = String(p.dropFirst(base.count + 1)); break }
        }
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        return p
    }

    /// `src/auth/` and `src/auth` cover everything below; globs use shell rules (`**` spans folders).
    static func patternMatches(_ pattern: String, _ path: String) -> Bool {
        if pattern == path { return true }
        let dir = pattern.hasSuffix("/") ? pattern : pattern + "/"
        if !pattern.contains("*") && !pattern.contains("?") && !pattern.contains("[") { return path.hasPrefix(dir) }
        let p = pattern.replacingOccurrences(of: "**/", with: "*").replacingOccurrences(of: "**", with: "*")
        return fnmatch(p, path, 0) == 0 || fnmatch(p, path, FNM_LEADING_DIR) == 0
    }

    static func patternsOverlap(_ a: String, _ b: String) -> Bool {
        patternMatches(a, b) || patternMatches(b, a)
    }

    /// Exclusive reservations by other active agents that cover any of `paths`.
    func reservationConflicts(paths: [String], project: String, except agentId: String?) -> [(String, Reservation)] {
        let active = activeReservations(project: project).filter { $0.agentId != agentId }
        var out: [(String, Reservation)] = []
        for path in paths {
            if let r = active.first(where: { $0.exclusive && Self.patternsOverlap($0.pattern, path) }) { out.append((path, r)) }
        }
        return out
    }

    /// Grants what it can; returns the patterns granted and those blocked by someone else.
    func reserve(agent: Agent, patterns raw: [String], minutes: Double, exclusive: Bool, reason: String)
        -> (granted: [String], blocked: [(String, Reservation)]) {
        let p = project(id: agent.projectId)
        let patterns = raw.map { Self.normalizePattern($0, agent: agent, project: p) }.filter { !$0.isEmpty }
        let others = activeReservations(project: agent.projectId).filter { $0.agentId != agent.id }
        var granted: [String] = [], blocked: [(String, Reservation)] = []
        let until = now() + minutes * 60
        for pat in patterns {
            if let r = others.first(where: { ($0.exclusive || exclusive) && Self.patternsOverlap($0.pattern, pat) }) {
                blocked.append((pat, r)); continue
            }
            // Renewing your own lease extends it.
            let mine = db.query("SELECT id FROM reservations WHERE agent_id=? AND pattern=? AND released_at IS NULL AND expires_at > ?",
                                [agent.id, pat, now()]).first
            if let mine {
                db.query("UPDATE reservations SET expires_at=?, exclusive=?, reason=? WHERE id=?",
                         [until, exclusive ? 1 : 0, reason, mine.i("id")])
            } else {
                db.query("INSERT INTO reservations(project_id, agent_id, pattern, exclusive, reason, created_at, expires_at) VALUES(?,?,?,?,?,?,?)",
                         [agent.projectId, agent.id, pat, exclusive ? 1 : 0, reason, now(), until])
            }
            granted.append(pat)
        }
        if !granted.isEmpty {
            addEvent(project: agent.projectId, agent: agent.id, kind: "reservation",
                     title: "\(agent.name) reserved \(granted.joined(separator: ", ").trunc(200)) until \(Fmt.time(until))",
                     detail: reason)
        }
        for (pat, r) in blocked {
            let holder = self.agent(id: r.agentId)?.name ?? r.agentId
            addEvent(project: agent.projectId, agent: agent.id, kind: "conflict",
                     title: "\(agent.name) couldn't reserve \(pat): held by \(holder)", ref: pat)
        }
        return (granted, blocked)
    }

    @discardableResult
    func releaseReservations(agentId: String, patterns: [String]?) -> Int {
        let rows = db.query("SELECT id, pattern FROM reservations WHERE agent_id=? AND released_at IS NULL AND expires_at > ?", [agentId, now()])
        var n = 0
        for r in rows where patterns == nil || patterns!.contains(r.s("pattern")) {
            db.query("UPDATE reservations SET released_at=? WHERE id=?", [now(), r.i("id")]); n += 1
        }
        return n
    }

    /// The human drops a lease from the app.
    func dropReservation(id: Int64) {
        guard let r = db.query("SELECT * FROM reservations WHERE id=?", [id]).first.map(Reservation.init) else { return }
        db.query("UPDATE reservations SET released_at=? WHERE id=?", [now(), id])
        addEvent(project: r.projectId, agent: nil, kind: "reservation", title: "You released the reservation on \(r.pattern)")
        sendMessage(project: r.projectId, to: r.agentId, from: nil,
                    text: "The human released your reservation on \(r.pattern). If you still need the file, reserve it again and let the others know.")
        changed()
    }

    func reservationsText(project: String) -> String {
        activeReservations(project: project).map { r in
            let who = agent(id: r.agentId)?.name ?? r.agentId
            return "  🔒 \(r.pattern) — \(who) until \(Fmt.time(r.expiresAt))\(r.exclusive ? "" : " (shared)")\(r.reason.isEmpty ? "" : " · \(r.reason)")"
        }.joined(separator: "\n")
    }

    /// git pre-commit: body = repo root, then staged paths. Returns a refusal message or nil.
    func handlePreCommit(_ body: String) -> String? {
        var lines = body.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return nil }
        // Same spelling as the intent was recorded with (git's top level; /var vs /private/var and the like).
        let root = repoRoot(lines.removeFirst())
        guard let project = projectFor(cwd: root), !lines.isEmpty else { return nil }
        // Who commits: the agent that just ran `git commit` in this checkout. A human commit is never blocked.
        guard let intent = commitIntent[root], now() - intent.at < AppSettings.approvalTimeout + 300 else { return nil }
        let conflicts = reservationConflicts(paths: lines, project: project.id, except: intent.agentId)
        guard !conflicts.isEmpty else { return nil }
        let me = agent(id: intent.agentId)
        let list = conflicts.map { path, r in
            "  \(path) — reserved by \(agent(id: r.agentId)?.name ?? r.agentId) until \(Fmt.time(r.expiresAt))\(r.reason.isEmpty ? "" : " (\"\(r.reason)\")")"
        }.joined(separator: "\n")
        addEvent(project: project.id, agent: intent.agentId, kind: "conflict",
                 title: "Commit by \(me?.name ?? "an agent") blocked: files reserved by others", detail: list)
        changed()
        return """
        AgentBoard: commit blocked — these files are reserved by other agents:
        \(list)
        Coordinate with the reservation holder (send_message) or drop these files from the commit (git restore --staged <file>).
        """
    }
}

// MARK: - Stuck / loop detection

struct StuckTracker {
    var failures: [(key: String, at: Double)] = []
    var recent: [String] = []
    var nudged = false
}

extension Core {
    private func flagStuck(_ agent: Agent, project: Project, reason: String) -> String? {
        guard AppSettings.stuckDetection else { return nil }
        let already = !(self.agent(id: agent.id)?.stuck ?? "").isEmpty
        setAgent(agent.id, ["stuck": reason])
        if !already {
            addEvent(project: project.id, agent: agent.id, kind: "stuck", title: "\(agent.name) seems stuck: \(reason)")
            notify?("\(agent.name) is stuck · \(project.name)", reason)
        }
        guard AppSettings.stuckNudge, stuckState[agent.id]?.nudged != true else { return nil }
        stuckState[agent.id, default: StuckTracker()].nudged = true
        return "[AgentBoard] Looks like you're going in circles: \(reason). Stop: figure out the cause, change your approach "
            + "or ask the human instead of repeating the same thing."
    }

    /// A failed tool call. The same call failing 3 times in 20 minutes, or 8 failures in one turn, means stuck.
    func noteFailure(agent: Agent, project: Project, tool: String, input: JSON, error: String) -> String? {
        let key = tool == "Bash" ? "$ " + input.s("command").oneLine.trunc(200) : tool + " " + jsonString(input).oneLine.trunc(200)
        var st = stuckState[agent.id] ?? StuckTracker()
        st.failures.removeAll { now() - $0.at > 1200 }
        st.failures.append((key, now()))
        stuckState[agent.id] = st
        let same = st.failures.filter { $0.key == key }.count
        if same >= 3 { return flagStuck(agent, project: project, reason: "`\(key.trunc(120))` failed \(same) times in a row") }
        if st.failures.count >= 8 { return flagStuck(agent, project: project, reason: "\(st.failures.count) errors in the last 20 minutes") }
        return nil
    }

    /// The same call over and over (5 of the last 20) without anything changing.
    func noteRepeat(agent: Agent, project: Project, key: String) -> String? {
        var st = stuckState[agent.id] ?? StuckTracker()
        st.recent.append(key)
        if st.recent.count > 20 { st.recent.removeFirst(st.recent.count - 20) }
        stuckState[agent.id] = st
        let n = st.recent.filter { $0 == key }.count
        guard n >= 5 else { return nil }
        let shown = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
        return flagStuck(agent, project: project, reason: "repeating the same thing (\(n) of the last 20 actions): \(shown.oneLine.trunc(120))")
    }

    func noteSuccess(agent: Agent, tool: String, input: JSON) {
        guard var st = stuckState[agent.id] else { return }
        let key = tool == "Bash" ? "$ " + input.s("command").oneLine.trunc(200) : tool + " " + jsonString(input).oneLine.trunc(200)
        st.failures.removeAll { $0.key == key }
        stuckState[agent.id] = st
    }
}

// MARK: - Permission requests, questions and plans answered from the app

extension Core {
    func startPermissionFlow(agent: Agent, project: Project, tool: String, input: JSON, suggestions: [Any],
                             sub: String, plain: Bool = false, reply: @escaping (Data?) -> Void) {
        let id = UUID().uuidString
        var kind = "permission"
        var summary = "", detail = ""
        var questions: [AskQuestion] = []
        switch tool {
        case "AskUserQuestion":
            kind = "question"
            questions = ((input["questions"] as? [JSON]) ?? []).map { q in
                AskQuestion(question: q.s("question"), header: q.s("header"),
                            options: ((q["options"] as? [JSON]) ?? []).map { AskOption(label: $0.s("label"), description: $0.s("description")) },
                            multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            summary = questions.first?.question ?? "Question"
        case "ExitPlanMode":
            kind = "plan"
            detail = input.s("plan")
            summary = "Plan ready — needs approval"
        case "Bash":
            summary = "$ " + input.s("command")
            detail = input.s("description")
        case "Edit", "MultiEdit":
            summary = "editing " + relativePath(input.s("file_path"), agent: agent, project: project)
            if tool == "Edit" {
                detail = "− " + input.s("old_string").trunc(1500).replacingOccurrences(of: "\n", with: "\n− ")
                    + "\n+ " + input.s("new_string").trunc(1500).replacingOccurrences(of: "\n", with: "\n+ ")
            } else {
                detail = jsonString(input).trunc(3000)
            }
        case "Write":
            summary = "writing " + relativePath(input.s("file_path"), agent: agent, project: project)
            detail = input.s("content").trunc(3000)
        default:
            let d = Self.describeTool(tool, input, agent: agent, project: project, core: self)
            summary = d.0
            detail = d.1.isEmpty ? jsonString(input).trunc(3000) : d.1
        }
        if !sub.isEmpty { summary = "↳ \(sub): " + summary }
        let timeout = AppSettings.permissionTimeout
        let pc = PendingCommit(id: id, agentId: agent.id, agentName: agent.name, projectId: project.id,
                               projectName: project.name, command: summary.trunc(2000), gitStatus: detail.trunc(20000),
                               createdAt: now(), deadline: now() + timeout, kind: kind, toolName: tool,
                               questions: questions, canAlwaysAllow: !suggestions.isEmpty)
        let work = DispatchWorkItem { [weak self] in self?.resolveCommit(id: id, allow: nil, comment: "") }
        pending[id] = PendingEntry(commit: pc, reply: reply, timer: work, toolInput: input,
                                   inputKey: tool + "|" + jsonString(input), suggestions: suggestions, plain: plain)
        setAgent(agent.id, ["status": "waiting", "last_action": kind == "question" ? "asking a question" : kind == "plan" ? "waiting for plan approval" : "waiting for permission: \(summary.oneLine.trunc(150))"])
        addEvent(project: project.id, agent: agent.id, kind: "permission",
                 title: "\(agent.name) " + (kind == "question" ? "asks: \(summary.trunc(180))" : kind == "plan" ? "proposes a plan" : "asks for permission: \(summary.oneLine.trunc(180))"),
                 detail: detail.trunc(4000), sub: sub)
        q.asyncAfter(deadline: .now() + timeout, execute: work)
        notifyRequest?(pc)
        changed()
    }

    func resolvePermission(_ e: PendingEntry, allow: Bool?, comment: String, answers: [String: String], always: Bool) {
        let c = e.commit
        func out(_ decision: JSON) -> Data { jsonData(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]) }
        switch allow {
        case .some(true):
            var d: JSON = ["behavior": "allow"]
            if e.plain {
                // Codex: nothing but the decision itself.
            } else if c.kind == "question" {
                var inp = e.toolInput
                inp["answers"] = answers
                d["updatedInput"] = inp
            } else if c.kind == "plan" {
                d["updatedInput"] = e.toolInput
            }
            if always, !e.suggestions.isEmpty, !e.plain {
                // Remember for this session only, never in settings files.
                d["updatedPermissions"] = e.suggestions.compactMap { s -> JSON? in
                    guard var j = s as? JSON else { return nil }
                    j["destination"] = "session"
                    return j
                }
            }
            e.reply(out(d))
            let what = c.kind == "question" ? "answered: " + answers.values.joined(separator: "; ").trunc(200)
                : c.kind == "plan" ? "plan approved" : "allowed" + (always ? " (for the rest of the session)" : "")
            addEvent(project: c.projectId, agent: c.agentId, kind: "permission", title: "\(c.agentName): \(what)", detail: comment)
            setAgent(c.agentId, ["status": "working", "last_action": what.trunc(200)])
            if !comment.isEmpty { sendMessage(project: c.projectId, to: c.agentId, from: nil, text: comment) }
        case .some(false):
            let msg = c.kind == "plan"
                ? "The human did not approve the plan in AgentBoard." + (comment.isEmpty ? "" : " What to change: \(comment)")
                : "The human denied this in AgentBoard." + (comment.isEmpty ? "" : " Comment: \(comment)")
            e.reply(out(["behavior": "deny", "message": msg]))
            addEvent(project: c.projectId, agent: c.agentId, kind: "permission",
                     title: "\(c.agentName): " + (c.kind == "plan" ? "plan sent back for changes" : "denied"), detail: comment)
            setAgent(c.agentId, ["status": "working"])
        case .none:
            // Timed out: the terminal prompt (shown all along) stays the place to answer.
            e.reply(nil)
        }
        changed()
    }

    /// The request was answered in the terminal (the tool ran or the turn moved on): forget it here.
    func dropPendingPermissions(agent: String, inputKey: String?) {
        for (id, e) in pending where e.commit.agentId == agent && e.commit.kind != "commit" {
            if let inputKey, e.inputKey != inputKey { continue }
            pending.removeValue(forKey: id)
            e.timer.cancel()
            e.reply(nil)
            requestResolved?(id)
        }
    }
}

// MARK: - Tasks launched from the board

extension Core {
    /// The first agent that starts in a folder a task was launched into takes that task.
    func claimLaunchedTask(_ a: Agent) {
        launches = launches.filter { now() - $0.value.at < 900 }
        guard let (dir, l) = launches.first(where: { a.cwd == $0.key || a.cwd.hasPrefix($0.key + "/") }) else { return }
        launches.removeValue(forKey: dir)
        guard let t = task(id: l.taskId) else { return }
        updateTask(t.id, status: .in_progress, assignee: .some(a.id), by: a.id)
    }
}

// MARK: - Overlap before it happens
//
// When a new request names files or folders another active agent is editing or has reserved, the agent
// hears about it before its first edit — not when the conflict warning fires halfway through.

extension Core {
    /// Path-like words in a request: `src/auth/`, `login.ts`, `./scripts/test.sh`, `Sources/AgentBoard/Core.swift:42`.
    static func mentionedPaths(in prompt: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\"()[]{},;<>«»"))
        var out: [String] = []
        for raw in prompt.components(separatedBy: separators) {
            var w = raw
            while let last = w.last, ".:!?".contains(last) { w.removeLast() }
            if let colon = w.firstIndex(of: ":"), w[w.index(after: colon)...].allSatisfy(\.isNumber) { w = String(w[..<colon]) }
            while w.hasPrefix("./") { w = String(w.dropFirst(2)) }
            guard w.count >= 4, !w.contains("://"), !w.hasPrefix("-") else { continue }
            let hasDir = w.contains("/")
            let ext = (w as NSString).pathExtension
            let base = (w as NSString).deletingPathExtension
            // "login.ts" yes; "e.g", "v1.2", "3.5" no.
            let hasExt = !ext.isEmpty && ext.count <= 6 && ext.first?.isLetter == true
                && ext.allSatisfy { $0.isLetter || $0.isNumber } && base.count >= 2 && base.contains { $0.isLetter }
            guard hasDir || hasExt else { continue }
            if !out.contains(w) { out.append(w) }
        }
        return out
    }

    /// Does a mentioned word point at this repo-relative path? A folder covers what's below it; a bare file
    /// name matches that file anywhere.
    static func mention(_ m: String, covers path: String) -> Bool {
        if m.hasSuffix("/") { return path.hasPrefix(m) || path + "/" == m }
        if path == m || path.hasSuffix("/" + m) || path.hasPrefix(m + "/") { return true }
        if m.hasPrefix("/") { return m.hasSuffix("/" + path) }
        return false
    }

    /// What the request touches that someone else is on right now: their recent edits (30 min) and reservations.
    func overlapWarning(prompt: String, agent: Agent) -> (text: String, who: [String])? {
        let mentions = Self.mentionedPaths(in: prompt)
        guard !mentions.isEmpty else { return nil }
        var hits: [String: [String]] = [:]   // agent name → what
        let others = db.query("SELECT * FROM file_touches WHERE project_id=? AND agent_id != ? AND last_at > ?",
                              [agent.projectId, agent.id, now() - 1800]).map(FileTouch.init)
        for f in others {
            guard mentions.contains(where: { Self.mention($0, covers: f.path) }),
                  let a = self.agent(id: f.agentId), a.isActive(staleMinutes: AppSettings.staleMinutes) else { continue }
            hits[a.name, default: []].append("edits \(f.path)")
        }
        for r in activeReservations(project: agent.projectId) where r.agentId != agent.id {
            guard mentions.contains(where: { Self.mention($0, covers: r.pattern) || Self.patternMatches(r.pattern, $0) }),
                  let a = self.agent(id: r.agentId) else { continue }
            hits[a.name, default: []].append("reserved \(r.pattern)" + (r.reason.isEmpty ? "" : " (\(r.reason))"))
        }
        guard !hits.isEmpty else { return nil }
        let lines = hits.keys.sorted().map { "- \($0): " + Array(Set(hits[$0]!)).sorted().prefix(4).joined(separator: "; ") }
        return ("[AgentBoard] Heads up before you start: this request touches what another agent is working on right now:\n"
                + lines.joined(separator: "\n")
                + "\nTalk to them first (send_message) or reserve_files the part you take, so you don't overwrite each other.",
                hits.keys.sorted())
    }
}
