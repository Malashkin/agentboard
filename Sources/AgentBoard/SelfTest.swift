import Foundation

/// `AgentBoard --self-test`: end-to-end checks of the core on a throwaway database, git repository and
/// Claude/Codex folders. Never touches your real data and never calls a model. Exit code = failures.
enum SelfTest {
    static var failures = 0
    static var passed = 0
    /// unit · contract · integration — reported separately.
    static var layer = "integration"
    static var byLayer: [String: (pass: Int, fail: Int)] = [:]
    static var failed: [String] = []

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        var c = byLayer[layer] ?? (0, 0)
        if ok { passed += 1; c.pass += 1; print("  ✓ \(name)") } else {
            failures += 1; c.fail += 1
            let d = detail()
            failed.append("[\(layer)] \(name)\(d.isEmpty ? "" : " — \(d)")")
            print("  ✗ \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
        byLayer[layer] = c
    }

    static func section(_ s: String, layer l: String = "integration") { layer = l; print("\n[\(l)] \(s)") }

    /// Must run before anything touches Core.shared / Integrations (they read these at first use).
    static func prepareEnvironment() -> String {
        let root = NSTemporaryDirectory() + "agentboard-selftest-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        for d in ["data", "claude/projects", "codex", "bridge", "worktrees", "repo"] {
            try? fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        setenv("AGENTBOARD_DATA_DIR", root + "/data", 1)
        setenv("AGENTBOARD_BRIDGE_DIR", root + "/bridge", 1)
        setenv("CLAUDE_CONFIG_DIR", root + "/claude", 1)
        setenv("CODEX_HOME", root + "/codex", 1)
        setenv("GEMINI_CLI_HOME", root + "/gemini-home", 1)
        setenv("AGENTBOARD_WORKTREE_ROOT", root + "/worktrees", 1)
        for (k, v) in ["GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@t"] {
            setenv(k, v, 1)
        }
        return root
    }

    static func run() -> Int32 {
        let root = prepareEnvironment()
        Pref.registerDefaults()
        let core = Core.shared
        do { try core.q.sync { try core.setup() } } catch { print("setup failed: \(error)"); return 1 }
        let repo = URL(fileURLWithPath: root + "/repo").resolvingSymlinksInPath().path
        func git(_ args: [String], _ cwd: String = repo) -> Shell.Result { Shell.git(args, cwd: cwd, timeout: 30) }
        _ = git(["init", "-q", "-b", "main"])
        try? "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(atPath: repo + "/src/auth", withIntermediateDirectories: true)
        try? "x\n".write(toFile: repo + "/src/auth/login.ts", atomically: true, encoding: .utf8)
        _ = git(["add", "-A"]); _ = git(["commit", "-qm", "init"])

        func hook(_ j: JSON, tool: String = "claude") -> JSON? {
            var out: Data?
            core.q.sync { core.handleClaudeHook(j, agentTool: tool) { out = $0 } }
            return out.flatMap { parseJSON($0) as? JSON }
        }
        func ev(_ name: String, _ sid: String, _ extra: JSON = [:]) -> JSON {
            var j: JSON = ["hook_event_name": name, "session_id": sid, "cwd": repo]
            for (k, v) in extra { j[k] = v }
            return j
        }

        unitSuite()

        section("Names and patterns", layer: "unit")
        check(Core.englishName("Бэтмен-2") == "Batman-2", "legacy names map to English")
        check(Core.patternMatches("src/auth/", "src/auth/login.ts"), "folder pattern covers files below")
        check(!Core.patternMatches("src/auth", "src/authx/y.ts"), "folder pattern doesn't match a sibling prefix")
        check(Core.patternMatches("src/**/*.ts", "src/a/b.ts"), "** glob spans folders")
        check(Core.patternsOverlap("src/auth/login.ts", "src/auth/"), "file and folder overlap")

        section("Project and sessions")
        let project: Project
        switch core.q.sync(execute: { core.addProject(path: repo) }) {
        case .success(let p): project = p
        case .failure(let e): print("addProject: \(e.message)"); return 1
        }
        let startCtx = hook(ev("SessionStart", "sA", ["source": "startup"]))
        _ = hook(ev("SessionStart", "sB", ["source": "startup"]))
        let a = core.q.sync { core.db.query("SELECT * FROM agents WHERE session_id='sA'").first.map(Agent.init) }!
        let b = core.q.sync { core.db.query("SELECT * FROM agents WHERE session_id='sB'").first.map(Agent.init) }!
        check(a.name != b.name, "each open session gets its own name", "\(a.name) / \(b.name)")
        check((startCtx?["hookSpecificOutput"] as? JSON)?.s("additionalContext").contains(a.id) == true, "SessionStart tells the agent its id")

        section("Reservations")
        let r = core.q.sync { core.reserve(agent: a, patterns: ["src/auth/", repo + "/a.txt"], minutes: 30, exclusive: true, reason: "refactor") }
        check(r.granted == ["src/auth/", "a.txt"], "reserve folder and absolute path", "\(r.granted)")
        let r2 = core.q.sync { core.reserve(agent: b, patterns: ["src/auth/login.ts"], minutes: 30, exclusive: true, reason: "") }
        check(r2.granted.isEmpty && r2.blocked.count == 1, "overlapping reservation is refused")
        let deny = hook(ev("PreToolUse", "sB", ["tool_name": "Edit", "tool_input": ["file_path": repo + "/src/auth/login.ts", "old_string": "x", "new_string": "y"]]))
        check((deny?["hookSpecificOutput"] as? JSON)?.s("permissionDecision") == "deny", "editing another agent's reserved file is denied")
        let touchedByB = core.q.sync { !core.db.query("SELECT 1 FROM file_touches WHERE agent_id=? AND path='src/auth/login.ts'", [b.id]).isEmpty }
        check(!touchedByB, "a denied edit isn't recorded as work on the file")
        _ = hook(ev("PreToolUse", "sB", ["tool_name": "Bash", "tool_input": ["command": "git commit -am wip"]]))
        let msg = core.q.sync { core.handlePreCommit(repo + "\nsrc/auth/login.ts\nREADME.md") }
        check(msg?.contains("src/auth/login.ts") == true, "pre-commit stops a commit touching a foreign reservation",
              "msg=\(msg ?? "nil") intents=\(core.q.sync { core.commitIntent.map { "\($0.key)=\($0.value.agentId)" } }) root=\(repo)")
        _ = hook(ev("PreToolUse", "sA", ["tool_name": "Bash", "tool_input": ["command": "git commit -am mine"]]))
        check(core.q.sync { core.handlePreCommit(repo + "\nsrc/auth/login.ts") } == nil, "the holder's own commit passes")
        let codexDeny = hook(ev("PreToolUse", "cx1", ["tool_name": "apply_patch",
                                                     "tool_input": ["command": "*** Begin Patch\n*** Update File: src/auth/login.ts\n@@\n-x\n+z\n*** End Patch"]]), tool: "codex")
        check((codexDeny?["hookSpecificOutput"] as? JSON)?.s("permissionDecision") == "deny", "Codex patch on a reserved file is denied")
        check(core.q.sync { core.hookSessions.contains("cx1") }, "Codex hook sessions are not replayed from the log")

        section("Questions and permissions")
        var answer: Data?
        core.q.sync {
            core.handleClaudeHook(ev("PermissionRequest", "sA", ["tool_name": "AskUserQuestion", "tool_input": [
                "questions": [["question": "Which DB?", "header": "DB", "options": [["label": "Postgres"], ["label": "SQLite"]], "multiSelect": false]]]])) { answer = $0 }
        }
        let qid = core.q.sync { core.pending.values.first { $0.commit.kind == "question" }?.commit.id }
        check(qid != nil, "a question waits in the app")
        if let qid { core.q.sync { core.resolveCommit(id: qid, allow: true, comment: "", answers: ["Which DB?": "SQLite"]) } }
        let dec = ((answer.flatMap { parseJSON($0) as? JSON }?["hookSpecificOutput"] as? JSON)?["decision"] as? JSON)
        check(((dec?["updatedInput"] as? JSON)?["answers"] as? [String: String])?["Which DB?"] == "SQLite", "the answer reaches the agent")
        var codexAnswer: Data?
        core.q.sync {
            core.handleClaudeHook(ev("PermissionRequest", "cx1", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"],
                                                                  "permission_suggestions": [["type": "addRules"]]]), agentTool: "codex") { codexAnswer = $0 }
        }
        let cid = core.q.sync { core.pending.values.first { $0.commit.agentName != "" && $0.commit.toolName == "Bash" }?.commit.id }
        if let cid { core.q.sync { core.resolveCommit(id: cid, allow: true, comment: "", always: true) } }
        let cdec = ((codexAnswer.flatMap { parseJSON($0) as? JSON }?["hookSpecificOutput"] as? JSON)?["decision"] as? JSON) ?? [:]
        check(cdec.s("behavior") == "allow" && cdec["updatedPermissions"] == nil, "Codex gets a plain allow (no extra fields it rejects)")
        var codexPlan: Data?
        core.q.sync {
            core.handleClaudeHook(ev("PermissionRequest", "cx1", ["tool_name": "ExitPlanMode", "tool_input": ["plan": "1. do it"]]),
                                  agentTool: "codex") { codexPlan = $0 }
        }
        if let pid = core.q.sync(execute: { core.pending.values.first { $0.commit.kind == "plan" }?.commit.id }) {
            core.q.sync { core.resolveCommit(id: pid, allow: true, comment: "") }
        }
        let pdec = ((codexPlan.flatMap { parseJSON($0) as? JSON }?["hookSpecificOutput"] as? JSON)?["decision"] as? JSON) ?? [:]
        check(pdec.s("behavior") == "allow" && pdec["updatedInput"] == nil, "Codex never gets updatedInput, even for a plan")
        var dropped: Data? = Data("x".utf8)
        core.q.sync {
            core.handleClaudeHook(ev("PermissionRequest", "sB", ["tool_name": "Bash", "tool_input": ["command": "ls"]])) { dropped = $0 }
        }
        _ = hook(ev("PostToolUse", "sB", ["tool_name": "Read", "tool_input": ["file_path": repo + "/a.txt"]]))
        check(core.q.sync { core.pending.count } == 1, "a different tool finishing doesn't drop the request (parallel tool calls)")
        _ = hook(ev("PostToolUse", "sB", ["tool_name": "Bash", "tool_input": ["command": "ls"]]))
        check(dropped == nil && core.q.sync { core.pending.isEmpty }, "answered in the terminal → request leaves the app")

        section("Stuck detection and subagents")
        _ = hook(ev("UserPromptSubmit", "sA", ["prompt": "fix the tests please"]))
        var nudge = ""
        for _ in 0..<3 {
            let o = hook(ev("PostToolUseFailure", "sA", ["tool_name": "Bash", "tool_input": ["command": "npm test"], "error": "Exit code 1"]))
            nudge = (o?["hookSpecificOutput"] as? JSON)?.s("additionalContext") ?? nudge
        }
        check(!(core.q.sync { core.agent(id: a.id)?.stuck ?? "" }).isEmpty, "three identical failures mark the agent stuck")
        check(nudge.contains("[AgentBoard]"), "the agent itself is nudged")
        _ = hook(ev("PreToolUse", "sA", ["tool_name": "Agent", "tool_input": ["description": "Find callers", "prompt": "…"]]))
        _ = hook(ev("SubagentStart", "sA", ["agent_id": "sub1", "agent_type": "Explore"]))
        _ = hook(ev("PreToolUse", "sA", ["agent_id": "sub1", "agent_type": "Explore", "tool_name": "Grep", "tool_input": ["pattern": "login("]]))
        _ = hook(ev("SubagentStop", "sA", ["agent_id": "sub1", "agent_type": "Explore", "last_assistant_message": "3 callers"]))
        let sub = core.q.sync { core.db.query("SELECT * FROM subagents WHERE id='sub1'").first.map(SubagentItem.init) }
        check(sub?.description == "Find callers" && sub?.status == "done" && sub?.result == "3 callers", "subagent tracked from start to result")

        section("Automatic tasks and time")
        TaskAutopilot.shared.onPrompt(b, "Add rate limiting to the login endpoint")
        TaskAutopilot.shared.flush()
        let auto = core.q.sync { core.db.query("SELECT * FROM tasks WHERE assignee=? AND created_by='auto'", [b.id]).first.map(TaskItem.init) }
        check(auto?.status == .in_progress && auto?.title.contains("rate limiting") == true, "a work request becomes a task in progress")
        TaskAutopilot.shared.onPrompt(b, "ok")
        TaskAutopilot.shared.flush()
        check(core.q.sync { core.db.query("SELECT COUNT(*) AS n FROM tasks WHERE assignee=?", [b.id]).first?.i("n") } == 1, "short replies don't create tasks")
        let t0 = now() - 3000
        core.q.sync {
            for dt in [0.0, 60, 120, 180] { core.addEvent(project: project.id, agent: b.id, kind: "action", title: "work", at: t0 + dt) }
            for dt in [1000.0, 1100] { core.addEvent(project: project.id, agent: b.id, kind: "action", title: "work", at: t0 + dt) }
        }
        let rep = core.q.sync { core.timeReport(from: t0 - 1, to: t0 + 2000, project: project.id) }
        check(abs(rep.totalWall - (180 + 100)) < 1, "time counts working stretches, not idle gaps", "\(rep.totalWall)")
        check(rep.clients.first?.tasks.first?.title.contains("#\(auto?.id ?? -1)") == true, "time is attributed to the task")
        core.onSessionEnd = { TaskAutopilot.shared.onSessionEnd($0) }
        _ = hook(ev("SessionEnd", "sB"))
        TaskAutopilot.shared.flush()
        core.q.sync {}
        check(core.q.sync { core.task(id: auto?.id ?? -1)?.status } == .review, "a finished session sends its task to review")

        section("Worktree, diff and merge")
        let task = core.q.sync { core.createTask(project: project.id, title: "Add README", details: "", client: "", status: .backlog, assignee: nil, createdBy: "user") }
        do {
            let (wt, branch, base) = try Workspaces.ensureWorktree(task: task, project: project)
            check(FileManager.default.fileExists(atPath: wt) && branch.hasPrefix("agent/\(task.id)") && base == "main", "worktree on its own branch")
            core.q.sync { core.db.update("tasks", id: task.id, ["worktree": wt, "branch": branch, "base_branch": base]) }
            try "# Hello\n".write(toFile: wt + "/README.md", atomically: true, encoding: .utf8)
            _ = git(["add", "-A"], wt); _ = git(["commit", "-qm", "readme"], wt)
            let t = core.q.sync { core.task(id: task.id)! }
            let files = DiffParser.parse(Workspaces.diff(task: t, project: project))
            check(files.map(\.path) == ["README.md"] && files[0].added == 1, "review diff shows the branch's changes", "\(files.map(\.path))")
            let merged = try Workspaces.merge(task: t, project: project)
            check(merged.contains(branch) && FileManager.default.fileExists(atPath: repo + "/README.md"), "merge brings the work into main")
            try Workspaces.removeWorktree(task: t, project: project)
            check(!FileManager.default.fileExists(atPath: wt), "worktree removed, branch kept")
        } catch {
            check(false, "worktree flow", error.localizedDescription)
        }

        section("History import")
        let key = project.path.map { $0 == "/" || $0 == "." || $0 == "_" ? "-" : String($0) }.joined()
        let dir = root + "/claude/projects/" + key
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let lines: [JSON] = [
            ["type": "user", "sessionId": "old1", "cwd": project.path, "timestamp": iso.string(from: Date().addingTimeInterval(-7200)),
             "message": ["role": "user", "content": "Rename the config loader"]],
            ["type": "assistant", "sessionId": "old1", "cwd": project.path, "timestamp": iso.string(from: Date().addingTimeInterval(-7100)),
             "message": ["role": "assistant", "content": [["type": "tool_use", "name": "Edit", "input": ["file_path": project.path + "/a.txt"]],
                                                          ["type": "text", "text": "Renamed."]]]],
        ]
        try? lines.map(jsonString).joined(separator: "\n").write(toFile: dir + "/old1.jsonl", atomically: true, encoding: .utf8)
        let imp = HistoryImporter.run(project: project, days: 30)
        check(imp.sessions == 1 && imp.events >= 3, "old Claude Code sessions are imported", "\(imp.sessions) sessions, \(imp.events) events")
        check(HistoryImporter.run(project: project, days: 30).sessions == 0, "importing again adds nothing")

        section("Pinning and cleanup")
        core.q.sync { core.pinAgent(a.id, to: project.id) }
        check(core.q.sync { core.db.query("SELECT pinned FROM agents WHERE id=?", [a.id]).first?.i("pinned") } == 1, "a session can be pinned to a project")
        core.q.sync {
            core.addEvent(project: project.id, agent: a.id, kind: "action", title: "ancient", at: now() - 100 * 86400)
            core.addEvent(project: project.id, agent: a.id, kind: "commit", title: "ancient commit", at: now() - 100 * 86400)
            core.cleanupOldData()
        }
        let left = core.q.sync { core.db.query("SELECT kind FROM events WHERE title LIKE 'ancient%'").map { $0.s("kind") } }
        check(left == ["commit"], "old detailed actions are cleaned, commits kept", "\(left)")

        section("HTTP safety", layer: "contract")
        func route(_ method: String, _ path: String, _ headers: [String: String]) -> Int {
            var status = 0
            let req = HTTPRequest(method: method, path: path, query: [:], headers: headers, body: Data())
            core.q.sync { core.route(req) { status = $0.status } }
            return status
        }
        check(route("GET", "/api/board", ["host": "127.0.0.1:7777", "x-agentboard-token": Auth.token]) == 200, "local requests with the token are served")
        check(route("GET", "/api/board", ["host": "evil.example:7777"]) == 403, "DNS-rebinding host is refused")
        check(route("POST", "/api/decide", ["host": "127.0.0.1:7777", "origin": "https://evil.example", "content-type": "application/json"]) == 403,
              "cross-site POST is refused")

        contractSuite(core: core, project: project)
        integrationSuite(core: core, project: project, repo: repo, root: root)
        gapSuite(core: core, project: project, repo: repo, root: root)
        hardeningSuite(core: core, project: project, repo: repo, root: root)
        projectsSuite(core: core, root: root)
        discoveryUnitSuite()
        deliverySuite(core: core, project: project, repo: repo)
        discoverySuite(core: core, root: root)

        print("")
        for l in ["unit", "contract", "integration"] {
            let c = byLayer[l] ?? (0, 0)
            print("\(l): \(c.pass) passed, \(c.fail) failed")
        }
        print("\n\(passed) passed, \(failures) failed")
        try? FileManager.default.removeItem(atPath: root)
        return Int32(failures)
    }
}
