import Foundation

/// MCP over Streamable HTTP (JSON responses only, no SSE). Runs on Core.q.
extension Core {
    static let mcpInstructions = """
    AgentBoard is a shared board for several AI agents (Claude Code, Codex) working on the same project; \
    the human watches it in the AgentBoard app. Use it to know who is doing what and to stay out of each other's way.
    • board — who is working right now, open tasks, recent commits and notes. Call it when you start working.
    • agent_activity(agent) — details of what a specific agent is doing: prompts, commands, files, last reply. \
    Use it when the human asks you to "check what the other agent / the other terminal / Batman is doing".
    • claim_task / create_task(claim=true) — take a task before working on it; update_task — status and outcome.
    • set_focus(focus, files) — announce what you are working on and which files you are touching.
    • send_message(to, text) — message another agent or everyone (to="all"); post_note — a note in the feed for the human.
    • reserve_files(paths, minutes, reason) / release_files(paths) — reserve files before editing them: \
    other agents can't edit or commit them while the reservation is active.
    • who_touches(path) — who recently changed a file and who has reserved it.
    • remember(text) / forget(id) — project memory: lasting facts every future session gets at its start.
    Claude Code is detected automatically. Other clients (Codex etc.) first call register_agent(cwd) \
    and pass the returned agent_id in every call.
    """

    private static func prop(_ type: String, _ desc: String) -> JSON { ["type": type, "description": desc] }
    private static let agentIdProp = prop("string", "Your agent_id (Claude Code is detected automatically and can omit it)")
    private static let projectProp = prop("string", "Project path, if agent_id is unknown")

    static var toolDefs: [JSON] {
        func tool(_ name: String, _ desc: String, _ props: JSON, _ required: [String] = [], readOnly: Bool = false) -> JSON {
            var p = props
            p["agent_id"] = agentIdProp
            p["project_path"] = projectProp
            return ["name": name, "description": desc,
                    "inputSchema": ["type": "object", "properties": p, "required": required],
                    "annotations": ["readOnlyHint": readOnly]]
        }
        let statusEnum: JSON = ["type": "string", "enum": TaskStatus.allCases.map(\.rawValue),
                                "description": "backlog | in_progress | review | done"]
        return [
            tool("board", "Project overview: active agents and what they are doing, open tasks, recent commits and notes.", [:], readOnly: true),
            tool("agent_activity", "What another agent is doing: its prompt, commands, changed files, commits, last reply. Without agent — a short overview of all agents in the project.",
                 ["agent": prop("string", "Agent name (e.g. \"Batman\") or its agent_id"),
                  "limit": prop("integer", "How many recent events to show (default 30)")], readOnly: true),
            tool("list_tasks", "List the project's tasks.",
                 ["status": statusEnum, "client": prop("string", "Filter by client"),
                  "include_done": prop("boolean", "Include finished tasks")], readOnly: true),
            tool("create_task", "Create a task on the shared board. claim=true — take it yourself right away.",
                 ["title": prop("string", "Short title"), "details": prop("string", "Details"),
                  "client": prop("string", "Client the work is for (if any)"), "status": statusEnum,
                  "claim": prop("boolean", "Take the task yourself right away")], ["title"]),
            tool("claim_task", "Take a task. Refuses if another active agent is already on it (force=true — take it over).",
                 ["task_id": prop("integer", "Task number"), "force": prop("boolean", "Take it over from another agent")], ["task_id"]),
            tool("update_task", "Update a task: status, outcome (note), client.",
                 ["task_id": prop("integer", "Task number"), "status": statusEnum,
                  "note": prop("string", "What was done / what is left"), "client": prop("string", "Client"),
                  "release": prop("boolean", "Unassign yourself from the task")], ["task_id"]),
            tool("set_focus", "Announce what you are working on right now and which files you are touching.",
                 ["focus": prop("string", "What you are working on"),
                  "files": ["type": "array", "items": ["type": "string"], "description": "File paths relative to the repository root"]],
                 ["focus"]),
            tool("send_message", "Send a message to another agent (it lands in its context) or to all agents in the project.",
                 ["to": prop("string", "Agent name, its agent_id, or \"all\""), "text": prop("string", "Message text")], ["to", "text"]),
            tool("post_note", "A note in the project feed for the human and other agents (decision, warning, outcome).",
                 ["text": prop("string", "Note text"), "client": prop("string", "Client, if the note is about one")], ["text"]),
            tool("remember", "Save a lasting fact about this project that every future agent session should know at its start: how to build or test, a module not to touch, a gotcha. One short fact per call; not for progress updates (use update_task / post_note).",
                 ["text": prop("string", "The fact, in one or two sentences")], ["text"]),
            tool("forget", "Remove a fact from project memory that is wrong or outdated (its #id is shown at session start and by list_memory).",
                 ["id": prop("integer", "Memory item number")], ["id"]),
            tool("list_memory", "The project's memory: lasting facts earlier sessions saved.", [:], readOnly: true),
            tool("who_touches", "Which agents recently changed a file and whether it is reserved.", ["path": prop("string", "File path")], ["path"], readOnly: true),
            tool("reserve_files", "Reserve files, folders or globs (src/auth/, *.sql, src/**/*.ts) before editing. While the reservation is active, other agents can't edit or commit them. Calling again extends the reservation.",
                 ["paths": ["type": "array", "items": ["type": "string"], "description": "Paths relative to the repository root, folders or globs"],
                  "minutes": prop("integer", "For how many minutes (default from settings, usually 30)"),
                  "exclusive": prop("boolean", "true (default) — only you; false — shared reservation, just a warning"),
                  "reason": prop("string", "Why, briefly — other agents and the human will see it")], ["paths"]),
            tool("release_files", "Release your reservations. Without paths — all of them.",
                 ["paths": ["type": "array", "items": ["type": "string"], "description": "Which reservations to release"]]),
            tool("register_agent", "Register on the board (for clients without hooks, e.g. Codex). Returns an agent_id.",
                 ["cwd": prop("string", "Absolute path of the current working directory"),
                  "tool": prop("string", "codex, cursor, …"), "name": prop("string", "Preferred name")], ["cwd"]),
        ]
    }

    func handleMCP(_ body: Data) -> Data? {
        guard let parsed = parseJSON(body) else {
            return jsonData(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = parsed as? [JSON] {
            let results = batch.compactMap { mcpOne($0) }
            return results.isEmpty ? nil : jsonData(results)
        }
        guard let msg = parsed as? JSON else { return nil }
        return mcpOne(msg).map(jsonData)
    }

    private func mcpOne(_ msg: JSON) -> JSON? {
        guard let id = msg["id"], !(id is NSNull) else { return nil } // notification
        let method = msg.s("method")
        let params = msg["params"] as? JSON ?? [:]
        func ok(_ result: Any) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            return ok([
                "protocolVersion": params.str("protocolVersion") ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "agentboard", "title": "AgentBoard", "version": AppInfo.version],
                "instructions": Self.mcpInstructions,
            ])
        case "ping":
            return ok([:] as JSON)
        case "tools/list":
            return ok(["tools": Self.toolDefs])
        case "resources/list":
            return ok(["resources": [] as [Any]])
        case "prompts/list":
            return ok(["prompts": [] as [Any]])
        case "tools/call":
            let name = params.s("name")
            let args = params["arguments"] as? JSON ?? [:]
            let (text, isError) = callTool(name, args)
            changed()
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    /// M2: a name an agent may choose for itself — short, plain, and impossible to confuse with the human or the app.
    static func acceptableAgentName(_ raw: String) -> String? {
        let n = raw.trimmed
        guard (1...40).contains(n.count),
              n.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} ._-]*$"#, options: .regularExpression) != nil else { return nil }
        let l = n.lowercased()
        for bad in ["human", "agentboard", "user", "system", "admin", "dashboard", "you"]
        where l == bad || l.split(whereSeparator: { " ._-".contains($0) }).contains(Substring(bad)) { return nil }
        return n
    }

    private func callTool(_ name: String, _ args: JSON) -> (String, Bool) {
        // Who is calling?
        var me: Agent?
        // The caller is identified only by its exact agent_id (H2): names are public and handed out in a fixed
        // order, so "Batman" must never be enough to act as Batman. Names stay valid as *targets* (send_message, agent_activity).
        if let aid = args.str("agent_id") { me = agent(id: aid.trimmed) }
        if me == nil { me = agentForMCPCall(tool: name, args: args) }
        var project: Project? = me.flatMap { self.project(id: $0.projectId) }
        if project == nil, let p = args.str("project_path") ?? args.str("cwd") { project = projectFor(cwd: p) }
        if project == nil { let all = allProjects(); if all.count == 1 { project = all[0] } }
        if let me { setAgent(me.id, ["last_seen": now()]) }

        if name == "register_agent" {
            let cwd = args.s("cwd")
            // Only a real match (cwd or an explicit project_path) — never the "single project" fallback,
            // which would silently attach a client started elsewhere to the wrong project.
            guard let p = projectFor(cwd: cwd) ?? args.str("project_path").flatMap({ projectFor(cwd: $0) }) else {
                return ("Folder \(cwd) doesn't belong to any AgentBoard project. The human needs to add the project in the app.", true)
            }
            let tool = args.str("tool") ?? "codex"
            // Codex sessions are already followed from their logs: reuse that agent instead of creating a twin.
            if let existing = agents(project: p.id).first(where: {
                $0.tool == tool && $0.status != "ended" && now() - $0.lastSeen < 600 && ($0.cwd == cwd || cwd.hasPrefix($0.cwd + "/"))
            }) {
                return ("Your agent_id: \(existing.id) (name \"\(existing.name)\"). Pass it in every agentboard call.\n\n"
                        + boardText(project: p, me: existing, includeRules: true), false)
            }
            let a = touchAgent(tool: tool, sessionId: "mcp-" + UUID().uuidString, project: p, cwd: cwd.isEmpty ? p.path : cwd,
                               transcript: nil, revive: true, name: args.str("name").flatMap(Self.acceptableAgentName))
            setAgent(a.id, ["status": "working", "last_action": "registered"])
            addEvent(project: p.id, agent: a.id, kind: "session_start", title: "\(a.name) connected (\(a.toolLabel))", detail: cwd)
            return ("Your agent_id: \(a.id) (name \"\(a.name)\"). Pass it in every agentboard call.\n\n"
                    + boardText(project: p, me: a, includeRules: true), false)
        }

        guard let project else {
            return ("Couldn't determine the project. Pass agent_id (from register_agent) or project_path.", true)
        }
        // Messages for the caller ride along with any tool result (main delivery path for Codex).
        let inbox = me.flatMap { takeInbox(agent: $0.id) }
        func done(_ text: String, _ err: Bool = false) -> (String, Bool) {
            (inbox.map { text + "\n\n" + $0 } ?? text, err)
        }

        switch name {
        case "board":
            return done(boardText(project: project, me: me, includeRules: false))

        case "agent_activity":
            if let key = args.str("agent") {
                guard let a = findAgent(key, project: project.id) else {
                    let names = agents(project: project.id).prefix(15).map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")
                    return done("Agent \"\(key)\" not found. Known agents: \(names.isEmpty ? "none" : names)", true)
                }
                let limit = Int(args.oi("limit") ?? 30)
                return done(activityText(a, limit: max(5, min(limit, 150))))
            }
            let list = agents(project: project.id).filter { $0.id != me?.id }.prefix(12)
            if list.isEmpty { return done("There are no other agents in the project.") }
            return done(list.map(describe).joined(separator: "\n")
                        + "\n\nMore about an agent: agent_activity(agent: \"name\").")

        case "list_tasks":
            var items = tasks(project: project.id, includeDone: args.b("include_done"))
            if let st = args.str("status") { items = items.filter { $0.status.rawValue == st } }
            if let c = args.str("client") { items = items.filter { $0.client.localizedCaseInsensitiveContains(c) } }
            if items.isEmpty { return done("No tasks.") }
            return done(items.prefix(60).map { t in
                let who = t.assignee.flatMap { agent(id: $0)?.name } ?? "unassigned"
                var s = "#\(t.id) [\(t.status.label), \(who)\(t.client.isEmpty ? "" : ", client: \(t.client)")] \(t.title)"
                if !t.details.isEmpty { s += "\n   " + t.details.oneLine.trunc(300) }
                return s
            }.joined(separator: "\n"))

        case "create_task":
            guard let title = args.str("title") else { return done("title is required", true) }
            let claim = args.b("claim") && me != nil
            var status = TaskStatus(rawValue: args.s("status")) ?? .backlog
            if claim && status == .backlog { status = .in_progress }
            let t = createTask(project: project.id, title: title, details: args.s("details"),
                               client: args.str("client") ?? project.client, status: status,
                               assignee: claim ? me?.id : nil, createdBy: me?.id ?? "agent")
            if claim, let me, me.focus.isEmpty { setAgent(me.id, ["focus": title]) }
            return done("Created task #\(t.id) \"\(t.title)\" (\(t.status.label))\(claim ? ", claimed by you" : "").")

        case "claim_task":
            guard let me else { return done("I don't know who you are. Pass agent_id (register_agent).", true) }
            guard let tid = args.oi("task_id"), let t = task(id: tid), t.projectId == project.id else {
                return done("Task not found", true)
            }
            if let owner = t.assignee, owner != me.id, let oa = agent(id: owner),
               oa.isActive(staleMinutes: AppSettings.staleMinutes), !args.b("force") {
                return done("Task #\(tid) is already being done by \(oa.name) (active). Pick another task or coordinate via send_message.", true)
            }
            updateTask(tid, status: t.status == .backlog ? .in_progress : nil, assignee: .some(me.id), by: me.id)
            setAgent(me.id, ["focus": t.title])
            return done("Task #\(tid) \"\(t.title)\" is now yours.\(t.details.isEmpty ? "" : "\nDescription: \(t.details)")")

        case "update_task":
            guard let tid = args.oi("task_id"), let t = task(id: tid), t.projectId == project.id else {
                return done("Task not found", true)
            }
            var status: TaskStatus?
            if let s = args.str("status") {
                guard let st = TaskStatus(rawValue: s) else { return done("Unknown status \(s)", true) }
                status = st
            }
            let assignee: String?? = args.b("release") ? .some(nil) : nil
            updateTask(tid, client: args.str("client"), status: status, assignee: assignee, by: me?.id)
            if let note = args.str("note") {
                addEvent(project: project.id, agent: me?.id, kind: "note",
                         title: "#\(tid) \"\(t.title.trunc(80))\":\(note.oneLine.trunc(200))", detail: note,
                         client: args.str("client") ?? t.client, ref: "\(tid)")
            }
            if let me, status == .done || status == .review, me.focus == t.title { setAgent(me.id, ["focus": ""]) }
            return done("Task #\(tid) updated.")

        case "set_focus":
            guard let me else { return done("I don't know who you are. Pass agent_id (register_agent).", true) }
            let focus = args.s("focus")
            setAgent(me.id, ["focus": focus.trunc(500)])
            let files = (args["files"] as? [String]) ?? []
            var warnings: [String] = []
            for f in files {
                touchFile(agent: me, path: f)
                let others = othersTouching(path: f, project: project.id, except: me.id)
                if !others.isEmpty { warnings.append("\(f) — recently changed by \(others.map { $0.name }.joined(separator: ", "))") }
            }
            addEvent(project: project.id, agent: me.id, kind: "focus", title: "\(me.name): \(focus.oneLine.trunc(200))",
                     detail: files.joined(separator: "\n"))
            return done("Focus recorded." + (warnings.isEmpty ? "" : "\nHeads up, possible overlaps:\n" + warnings.joined(separator: "\n")))

        case "send_message":
            // Anonymous senders would be shown as the human (M2): only an identified agent may send.
            guard let me else { return done("I don't know who you are. Pass agent_id (register_agent).", true) }
            guard let text = args.str("text") else { return done("text is required", true) }
            let to = args.s("to")
            if to.isEmpty || ["all", "все", "всем", "*"].contains(to.lowercased()) {
                let n = sendMessage(project: project.id, to: nil, from: me, text: text)
                return done(n == 0 ? "No other active agents — the message was recorded in the feed." : "Sent to \(n) agent(s).")
            }
            guard let target = findAgent(to, project: project.id) else { return done("Agent \"\(to)\" not found", true) }
            sendMessage(project: project.id, to: target.id, from: me, text: text)
            let st = target.displayStatus(staleMinutes: AppSettings.staleMinutes)
            let hint = st == .working ? "it will get it on its next action"
                : "currently \(st.label); it will get it when the human writes to it again or it calls agentboard"
            return done("Message for \(target.name) queued — \(hint).")

        case "remember":
            guard let text = args.str("text"), !text.trimmed.isEmpty else { return done("text is required", true) }
            guard let m = remember(project: project.id, text: text, by: me) else { return done("Already in project memory.") }
            return done("Saved to project memory as #\(m.id). Every new session in \(project.name) will see it at its start.")

        case "forget":
            guard let id = args.oi("id") else { return done("id is required", true) }
            return forget(memory: id, project: project.id) ? done("Removed #\(id) from project memory.") : done("No memory item #\(id) in this project.", true)

        case "list_memory":
            let text = memoryText(project: project.id)
            return done(text.isEmpty ? "Project memory is empty." : text)

        case "post_note":
            guard let text = args.str("text") else { return done("text is required", true) }
            addEvent(project: project.id, agent: me?.id, kind: "note",
                     title: "\(me?.name ?? "Agent"): \(text.oneLine.trunc(200))", detail: text, client: args.s("client"))
            return done("Note added to the feed.")

        case "reserve_files":
            guard let me else { return done("I don't know who you are. Pass agent_id (register_agent).", true) }
            let paths = (args["paths"] as? [String]) ?? args.str("paths").map { [$0] } ?? []
            guard !paths.isEmpty else { return done("paths is required", true) }
            let minutes = Double(args.oi("minutes") ?? Int64(AppSettings.reservationMinutes))
            let r = reserve(agent: me, patterns: paths, minutes: max(1, min(minutes, 480)),
                            exclusive: args["exclusive"] as? Bool ?? true, reason: args.s("reason"))
            var lines: [String] = []
            if !r.granted.isEmpty { lines.append("Reserved until \(Fmt.time(now() + minutes * 60)): \(r.granted.joined(separator: ", "))") }
            for (pat, res) in r.blocked {
                lines.append("Failed: \(pat) — already held by \(agent(id: res.agentId)?.name ?? res.agentId) until \(Fmt.time(res.expiresAt))\(res.reason.isEmpty ? "" : " (\"\(res.reason)\")"). Coordinate via send_message.")
            }
            return done(lines.joined(separator: "\n"), r.granted.isEmpty)

        case "release_files":
            guard let me else { return done("I don't know who you are. Pass agent_id (register_agent).", true) }
            let p = project
            let paths = (args["paths"] as? [String])?.map { Self.normalizePattern($0, agent: me, project: p) }
            let n = releaseReservations(agentId: me.id, patterns: paths)
            if n > 0 { addEvent(project: project.id, agent: me.id, kind: "reservation", title: "\(me.name) released reservations (\(n))") }
            return done(n == 0 ? "No active reservations found." : "Reservations released: \(n).")

        case "who_touches":
            let path = args.s("path")
            let rel = me.map { relativePath(path, agent: $0, project: project) } ?? path
            let held = activeReservations(project: project.id).filter { Self.patternsOverlap($0.pattern, rel) }
            let heldText = held.map { "🔒 reserved: \(agent(id: $0.agentId)?.name ?? $0.agentId) until \(Fmt.time($0.expiresAt))\($0.reason.isEmpty ? "" : " (\"\($0.reason)\")")" }
            let rows = db.query("SELECT * FROM file_touches WHERE project_id=? AND (path=? OR path LIKE ?) ORDER BY last_at DESC LIMIT 10",
                                [project.id, rel, "%" + rel]).map(FileTouch.init)
            if rows.isEmpty { return done((heldText + ["No agent has touched \(rel) recently."]).joined(separator: "\n")) }
            return done((heldText + rows.map { f in
                let a = agent(id: f.agentId)
                return "- \(a?.name ?? f.agentId) (\(a?.displayStatus(staleMinutes: AppSettings.staleMinutes).label ?? "?")): \(f.path), ×\(f.count), \(Fmt.rel(f.lastAt))"
            }).joined(separator: "\n"))

        default:
            return done("Unknown tool \(name)", true)
        }
    }
}
