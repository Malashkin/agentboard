import Foundation

/// Deterministic RNG for property-based checks (SplitMix64): the same seed gives the same cases every run.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SelfTest {
    static func randomString(_ rng: inout SeededRNG, alphabet: [Character], maxLen: Int) -> String {
        let n = Int.random(in: 0...maxLen, using: &rng)
        return String((0..<n).map { _ in alphabet.randomElement(using: &rng)! })
    }

    // MARK: - Unit: pure logic

    static func unitSuite() {
        section("Recognizing git commands", layer: "unit")
        for cmd in ["git commit -m 'x'", "git commit", "cd repo && git commit -am wip", "git -C /tmp/r commit -m x",
                    "git --no-pager commit -m x", "(git commit -m x)", "git add . ; git commit -m x"] {
            check(Core.isGitCommit(cmd), "commit detected: \(cmd)")
        }
        for cmd in ["git commit-tree abc", "git log --grep commit", "git status", "gitcommit -m x", "git show HEAD:commit.txt"] {
            check(!Core.isGitCommit(cmd), "not a commit: \(cmd)")
        }
        check(Core.isGitPush("git push origin main") && Core.isGitPush("git push"), "push detected")
        check(!Core.isGitPush("git stash push") && !Core.isGitPush("git pushx"), "stash push / pushx are not pushes")

        section("Reservation patterns", layer: "unit")
        let cases: [(String, String, Bool)] = [
            ("src/auth/", "src/auth/login.ts", true), ("src/auth", "src/auth/login.ts", true),
            ("src/auth", "src/authx/a.ts", false), ("src/auth/login.ts", "src/auth/login.ts", true),
            ("src/auth/login.ts", "src/auth/login.tsx", false), ("src/**/*.ts", "src/a/b/c.ts", true),
            ("src/**/*.ts", "lib/a.ts", false), ("*.sql", "db/schema.sql", true), ("a.txt", "b.txt", false),
        ]
        for (p, path, want) in cases {
            check(Core.patternMatches(p, path) == want, "\(p) \(want ? "covers" : "does not cover") \(path)")
        }
        var rng = SeededRNG(state: 42)
        let pool = ["src/", "src/auth/", "src/auth/login.ts", "src/**/*.ts", "*.md", "docs/a.md", "lib/x.swift", "README.md", "src/authx/y.ts"]
        var symmetric = true
        for _ in 0..<200 {
            let a = pool.randomElement(using: &rng)!, b = pool.randomElement(using: &rng)!
            if Core.patternsOverlap(a, b) != Core.patternsOverlap(b, a) { symmetric = false }
        }
        check(symmetric, "property: overlap is symmetric (200 random pairs)")
        let proj = Project(["id": "p", "name": "app", "path": "/Users/x/app", "common_dir": "", "client": "", "created_at": 0.0, "aliases": "/Users/x/old-app"])
        check(Core.normalizePattern("/Users/x/app/src/a.ts", agent: nil, project: proj) == "src/a.ts", "absolute path inside the project becomes relative")
        check(Core.normalizePattern("./src/a.ts", agent: nil, project: proj) == "src/a.ts", "leading ./ is dropped")
        check(Core.normalizePattern("/etc/hosts", agent: nil, project: proj) == "/etc/hosts", "path outside the project is kept as is")

        section("Projects mentioned in tool input", layer: "unit")
        check(proj.isMentioned(in: "edit /Users/x/app/src/a.swift"), "file inside the project")
        check(proj.isMentioned(in: "cd /Users/x/app && swift build"), "the project folder itself")
        check(!proj.isMentioned(in: "cat /Users/x/app2/readme"), "a sibling folder with the same prefix is not the project")
        check(proj.isMentioned(in: "ls /Users/x/old-app/Sources"), "a former location (alias) counts")

        section("Codex patches and commands", layer: "unit")
        let patch = "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-x\n+y\n*** Add File: src/new.ts\n+hi\n*** Delete File: old.ts\n*** End Patch"
        let pf = Core.patchFiles(patch)
        check(pf.map(\.path) == ["src/a.ts", "src/new.ts", "old.ts"] && pf.map(\.verb) == ["editing", "creating", "deleting"],
              "patch files and verbs", "\(pf)")
        check(Core.patchFiles("no patch here").isEmpty, "text without a patch yields no files")
        check(Core.codexCommand(["command": ["bash", "-lc", "npm test"]]) == "npm test", "shell wrapper unwrapped")
        check(Core.codexCommand(["command": ["ls", "-la"]]) == "ls -la", "argv joined")
        check(Core.codexCommand(["cmd": "make"]) == "make" && Core.codexCommand([:]).isEmpty, "string command / missing command")

        section("Diff parsing", layer: "unit")
        let diff = """
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +x
        +y
        """
        let files = DiffParser.parse(diff)
        check(files.map(\.path) == ["a.txt", "new.txt"], "files in order", "\(files.map(\.path))")
        if files.count == 2 {
            check(files[0].added == 1 && files[0].removed == 1 && files[1].added == 2, "added/removed counts")
            let two = files[0].lines.first { $0.kind == .add }
            check(two?.text == "TWO" && two?.newNo == 2, "line numbers follow the hunk header", "\(String(describing: two))")
            check(files[1].lines.filter { $0.kind == .add }.map(\.newNo) == [1, 2], "new file numbered from 1")
        }
        var okNumbers = true, okCounts = true
        for _ in 0..<100 {
            let start = Int.random(in: 1...500, using: &rng)
            var body: [String] = [], adds = 0, dels = 0, ctx = 0
            for _ in 0..<Int.random(in: 1...30, using: &rng) {
                switch Int.random(in: 0...2, using: &rng) {
                case 0: body.append("+a"); adds += 1
                case 1: body.append("-d"); dels += 1
                default: body.append(" c"); ctx += 1
                }
            }
            let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -\(start),\(dels + ctx) +\(start),\(adds + ctx) @@\n" + body.joined(separator: "\n")
            guard let f = DiffParser.parse(text).first else { okCounts = false; continue }
            if f.added != adds || f.removed != dels { okCounts = false }
            let news = f.lines.compactMap { $0.kind == .del || $0.kind == .hunk ? nil : $0.newNo }
            if news != Array(start..<(start + adds + ctx)) { okNumbers = false }
        }
        check(okCounts, "property: added/removed equal the +/- lines (100 random hunks)")
        check(okNumbers, "property: new-side line numbers are consecutive from the hunk start")

        section("Branch slugs and shell quoting", layer: "unit")
        check(Workspaces.slug("Добавить логин API") == "dobavit-login-api", "Cyrillic is transliterated", Workspaces.slug("Добавить логин API"))
        let alphabet = Array("abcXYZ019 -_./\\'\"$`;&|*?~!@#%^()[]{}<>абвёжщ😀\n\t")
        var slugOK = true
        for _ in 0..<300 {
            let s = Workspaces.slug(randomString(&rng, alphabet: alphabet, maxLen: 80))
            if s.count > 40 || (!s.isEmpty && s.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil) { slugOK = false }
        }
        check(slugOK, "property: slugs are safe for paths and branches ([a-z0-9-], ≤40, no leading/trailing/double -)")
        var quoteOK = true, failedSample = ""
        for _ in 0..<60 {
            let s = randomString(&rng, alphabet: alphabet, maxLen: 30)
            let r = Shell.run("/bin/sh", ["-c", "printf %s " + Workspaces.shq(s)], timeout: 5)
            if r.out != s { quoteOK = false; failedSample = s }
        }
        check(quoteOK, "property: shell-quoted strings reach the program unchanged (60 random strings)", failedSample.debugDescription)

        section("Security helpers", layer: "unit")
        for (ct, simple) in [("text/plain", true), ("TEXT/PLAIN; charset=utf-8", true), ("application/x-www-form-urlencoded", true),
                             ("multipart/form-data; boundary=x", true), (nil, true), ("application/json", false), ("application/octet-stream", false)] as [(String?, Bool)] {
            check(Core.isBrowserSimpleContentType(ct) == simple, "content type \(ct ?? "none") is \(simple ? "" : "not ")browser-simple")
        }
        check(Core.isTTYName("ttys004") && !Core.isTTYName("ttys") && !Core.isTTYName("../ttys1") && !Core.isTTYName("ttys1; rm"),
              "only ttysNNN is accepted as a terminal name")
        let args = SummaryService.modelArguments
        func hasEmptyTools(_ a: [String]) -> Bool { a.indices.contains { a[$0] == "--tools" && $0 + 1 < a.count && a[$0 + 1].isEmpty } }
        check(hasEmptyTools(args) && args.contains("--safe-mode") && args.contains("--no-session-persistence"),
              "M1: the evening summary runs claude without tools, MCP or a saved session", args.joined(separator: " "))
        let m = Shell.modelArgs(model: "haiku")
        check(hasEmptyTools(m) && m.contains("--safe-mode") && m.suffix(2) == ["--model", "haiku"], "every model call uses the same restricted arguments")
        check(SessionDelivery.agentInForeground(psOutput: "Ss   -zsh\nS+   claude", tool: "claude"), "M3: claude in the foreground → may type")
        check(!SessionDelivery.agentInForeground(psOutput: "Ss+  -zsh\nS    claude", tool: "claude"), "M3: shell in the foreground (agent exited or in background) → don't type")
        check(!SessionDelivery.agentInForeground(psOutput: "S+   vim", tool: "claude"), "M3: another program in the foreground → don't type")
        check(SessionDelivery.agentInForeground(psOutput: "Ss   -bash\nS+   /usr/local/bin/codex", tool: "codex"), "M3: codex by full path → may type")
        check(!SessionDelivery.agentInForeground(psOutput: "", tool: "claude"), "M3: no processes → don't type")

        section("Prompts, names, time, timestamps", layer: "unit")
        check(Core.isSystemPrompt("<task-notification>\n<task-id>x</task-id>") && Core.isSystemPrompt("  <system-reminder>hi"), "system turns recognized")
        check(!Core.isSystemPrompt("Please fix <b>bold</b> in the header"), "a human prompt that contains a tag is not a system turn")
        check(TaskAutopilot.isWorkRequest("Add rate limiting to the login endpoint"), "a real request is work")
        check(!TaskAutopilot.isWorkRequest("ok") && !TaskAutopilot.isWorkRequest("/compact") && !TaskAutopilot.isWorkRequest("continue."), "short replies and commands are not work")
        check(TaskAutopilot.clean("<pasted_content id=\"1\">fix login</pasted_content>") == "fix login", "tags stripped, content kept")
        check(Core.legacyHeroNames.count == Core.heroNames.count &&
              zip(Core.legacyHeroNames, Core.heroNames).allSatisfy { Core.englishName($0) == $1 }, "every legacy name maps to the hero at the same position")
        check(Core.englishName("Бэтмен-3") == "Batman-3" && Core.englishName("Nobody") == nil, "suffix kept; unknown names untouched")
        check(Set(Core.heroNames).count == Core.heroNames.count, "hero names are unique")
        check(TimeReport.format(10) == "<1 min" && TimeReport.format(60) == "1 min" && TimeReport.format(3600) == "1 h 00 min"
              && TimeReport.format(5400) == "1 h 30 min", "durations formatted",
              [10.0, 60, 3600, 5400].map(TimeReport.format).joined(separator: " | "))
        let t1 = HistoryImporter.ts("2026-11-09T10:00:00.250Z"), t2 = HistoryImporter.ts("2026-11-09T10:00:01Z")
        check(t1 != nil && t2 != nil && t2! - t1! == 0.75, "ISO timestamps with and without fractions")
        check(HistoryImporter.ts("yesterday") == nil, "garbage timestamp rejected")
    }

    // MARK: - Contract: MCP and HTTP shapes

    static func contractSuite(core: Core, project: Project) {
        section("MCP protocol", layer: "contract")
        func rpc(_ obj: Any) -> Any? {
            core.q.sync { core.handleMCP(jsonData(obj)) }.flatMap { parseJSON($0) }
        }
        let initR = rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]) as? JSON
        let initRes = initR?["result"] as? JSON
        check((initRes?["serverInfo"] as? JSON)?.s("name") == "agentboard" && initRes?.s("protocolVersion") == "2025-06-18",
              "initialize returns server info and echoes the protocol version")
        check(!(initRes?.s("instructions") ?? "").isEmpty, "initialize carries instructions for agents")
        let tools = ((rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]) as? JSON)?["result"] as? JSON)?["tools"] as? [JSON] ?? []
        let names = tools.map { $0.s("name") }
        let expected = ["board", "agent_activity", "list_tasks", "create_task", "claim_task", "update_task", "set_focus",
                        "send_message", "post_note", "who_touches", "reserve_files", "release_files", "register_agent"]
        check(Set(names) == Set(expected) && names.count == expected.count, "tools/list exposes exactly the documented tools", "\(names)")
        let schemasOK = tools.allSatisfy { t in
            guard let sch = t["inputSchema"] as? JSON, sch.s("type") == "object", let props = sch["properties"] as? JSON else { return false }
            return ((sch["required"] as? [String]) ?? []).allSatisfy { props[$0] != nil }
        }
        check(schemasOK, "every tool has an object schema whose required fields are declared")
        let unknown = ((rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nope", "arguments": [:]]]) as? JSON)?["result"] as? JSON)
        check(unknown?["isError"] as? Bool == true, "unknown tool → isError result")
        let missing = ((rpc(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                             "params": ["name": "send_message", "arguments": ["project_path": project.path]]]) as? JSON)?["result"] as? JSON)
        check(missing?["isError"] as? Bool == true, "missing required argument → isError result")
        let parse = core.q.sync { core.handleMCP(Data("{not json".utf8)) }.flatMap { parseJSON($0) as? JSON }
        check((parse?["error"] as? JSON)?["code"] as? Int == -32700, "malformed JSON → -32700")
        check(((rpc(["jsonrpc": "2.0", "id": 5, "method": "nope/nope"]) as? JSON)?["error"] as? JSON)?["code"] as? Int == -32601, "unknown method → -32601")
        check(core.q.sync { core.handleMCP(jsonData(["jsonrpc": "2.0", "method": "notifications/initialized"])) } == nil,
              "notification (no id) gets no response")
        let batch = rpc([["jsonrpc": "2.0", "id": 6, "method": "ping"], ["jsonrpc": "2.0", "id": 7, "method": "ping"]]) as? [Any]
        check(batch?.count == 2, "batch request → one response per call")

        section("HTTP routes", layer: "contract")
        func call(_ method: String, _ path: String, _ body: Any? = nil, query: [String: String] = [:]) -> (Int, JSON?) {
            var status = 0, out: Data?
            let req = HTTPRequest(method: method, path: path, query: query,
                                  headers: ["host": "127.0.0.1:7777", "content-type": "application/json"],
                                  body: body.map { jsonData($0) } ?? Data())
            core.q.sync { core.route(req) { status = $0.status; out = $0.body } }
            // Async routes (launch) reply off the queue; give them a moment.
            for _ in 0..<50 where status == 0 { Thread.sleep(forTimeInterval: 0.05) }
            return (status, out.flatMap { parseJSON($0) as? JSON })
        }
        let health = call("GET", "/health")
        check(health.0 == 200 && health.1?["ok"] as? Bool == true && health.1?.s("app") == "AgentBoard", "GET /health → 200 {ok, app, version}")
        check(call("GET", "/nope").0 == 404, "unknown path → 404")
        check(call("GET", "/mcp").0 == 405, "GET /mcp → 405 (no SSE)")
        check(call("POST", "/api/decide", ["id": "missing", "allow": true]).0 == 404, "decide on an unknown request → 404")
        check(call("POST", "/api/tasks", ["project_path": project.path]).0 == 400, "create task without title → 400")
        check(call("POST", "/api/tasks", ["project_path": "/nowhere", "title": "x"]).0 == 400, "create task in an unknown project → 400")
        let created = call("POST", "/api/tasks", ["project_path": project.path, "title": "Contract task"])
        check(created.0 == 200 && (created.1?["id"] as? Int ?? 0) > 0 && created.1?.s("title") == "Contract task", "create task → 200 {id, title}")
        check(call("POST", "/api/tasks/launch", ["task_id": 999_999]).0 == 404, "launch an unknown task → 404")
        section("Browser requests are refused (H1)", layer: "contract")
        func raw(_ method: String, _ path: String, _ headers: [String: String], _ body: String = "{}") -> Int {
            var status = 0
            var h = ["host": "127.0.0.1:7777"]
            for (k, v) in headers { h[k] = v }
            let req = HTTPRequest(method: method, path: path, query: [:], headers: h, body: Data(body.utf8))
            core.q.sync { core.route(req) { status = $0.status } }
            return status
        }
        let listCall = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        check(raw("POST", "/mcp", ["origin": "http://127.0.0.1.evil.example", "content-type": "text/plain"], listCall) == 403,
              "regression: a look-alike origin (127.0.0.1.evil.example) is refused")
        check(raw("POST", "/mcp", ["origin": "http://localhost.evil.example", "content-type": "application/json"], listCall) == 403,
              "regression: localhost.evil.example is refused")
        check(raw("GET", "/health", ["origin": "http://127.0.0.1:7777"]) == 403, "any Origin at all is refused (browsers only)")
        check(raw("POST", "/mcp", ["content-type": "text/plain"], listCall) == 415, "text/plain POST (no-preflight browser request) → 415")
        check(raw("POST", "/mcp", ["content-type": "application/x-www-form-urlencoded"], listCall) == 415, "form POST → 415")
        check(raw("POST", "/mcp", [:], listCall) == 415, "POST without a content type → 415")
        check(raw("POST", "/mcp", ["content-type": "application/json; charset=utf-8"], listCall) == 200, "our clients' JSON POST is served")
        check(raw("POST", "/hook/git-precommit", ["content-type": "application/octet-stream"], "/nowhere\na.txt") == 200,
              "the git pre-commit bridge (binary body) is served")
        check(raw("GET", "/health", [:]) == 200, "plain GET without Origin is served")

        let pending = call("GET", "/api/pending")
        check(pending.0 == 200 && pending.1?["pending"] is [Any], "GET /api/pending → {pending: [...]}")
    }

    // MARK: - Integration: real wiring, files, git, the bridge

    static func integrationSuite(core: Core, project: Project, repo: String, root: String) {
        func hook(_ j: JSON, tool: String = "claude") -> JSON? {
            var out: Data?
            core.q.sync { core.handleClaudeHook(j, agentTool: tool) { out = $0 } }
            return out.flatMap { parseJSON($0) as? JSON }
        }

        section("System turns are not the human's requests (regression)")
        _ = hook(["hook_event_name": "SessionStart", "session_id": "sys1", "cwd": repo, "source": "startup"])
        _ = hook(["hook_event_name": "UserPromptSubmit", "session_id": "sys1", "cwd": repo, "prompt": "Rename the settings screen"])
        _ = hook(["hook_event_name": "UserPromptSubmit", "session_id": "sys1", "cwd": repo, "prompt": "<task-notification><task-id>b1</task-id></task-notification>"])
        TaskAutopilot.shared.flush()
        let sys = core.q.sync { core.db.query("SELECT * FROM agents WHERE session_id='sys1'").first.map(Agent.init) }
        check(sys?.lastPrompt == "Rename the settings screen", "last request stays the human's", sys?.lastPrompt ?? "nil")
        let sysPrompts = core.q.sync { core.db.query("SELECT COUNT(*) AS n FROM events WHERE agent_id=? AND kind='prompt'", [sys?.id ?? ""]).first?.i("n") ?? 0 }
        check(sysPrompts == 1, "the notification is not recorded as a prompt", "\(sysPrompts)")

        section("Codex rollout log")
        var st = CodexWatcher.FileState(offset: 0, sessionId: "", cwd: "")
        let lines: [JSON] = [
            ["type": "session_meta", "payload": ["id": "cx-log-1", "cwd": repo]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Make the tests pass"]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "shell", "arguments": "{\"command\":[\"bash\",\"-lc\",\"npm test\"]}"]],
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "input": "*** Begin Patch\n*** Update File: src/x.ts\n*** End Patch"]],
            ["type": "event_msg", "payload": ["type": "task_complete", "last_agent_message": "Tests pass now."]],
        ]
        core.q.sync { for l in lines { core.handleCodexLog(l, state: &st) } }
        let cx = core.q.sync { core.db.query("SELECT * FROM agents WHERE tool='codex' AND session_id='cx-log-1'").first.map(Agent.init) }
        check(cx != nil, "Codex session becomes an agent")
        let cxEvents = core.q.sync { core.db.query("SELECT kind, title, detail FROM events WHERE agent_id=? ORDER BY id", [cx?.id ?? ""]) }
        let kinds = cxEvents.map { $0.s("kind") }
        check(kinds.contains("prompt") && kinds.contains("turn_done"), "request and finished turn recorded", "\(kinds)")
        check(cxEvents.contains { $0.s("title") == "$ npm test" }, "shell command unwrapped from bash -lc")
        check(cxEvents.contains { $0.s("title").contains("src/x.ts") }, "patched file recorded")
        check(cxEvents.contains { $0.s("kind") == "turn_done" && $0.s("detail") == "Tests pass now." }, "final answer recorded")

        section("Installers stay inside the configured folders (regression)")
        let claudeDir = root + "/claude", codexDir = root + "/codex"
        let settingsPath = Integrations.claudeSettings
        let insideClaude = settingsPath.hasPrefix(claudeDir + "/")
        check(insideClaude, "Claude settings path follows CLAUDE_CONFIG_DIR", settingsPath)
        check(Integrations.codexConfig.hasPrefix(codexDir + "/") && Integrations.codexHooks.hasPrefix(codexDir + "/"),
              "Codex paths follow CODEX_HOME", Integrations.codexConfig)
        if insideClaude {
            // Never run against the real ~/.claude: only when the path is the test folder.
            let existing: JSON = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "bash herdr.sh session"]]]]],
                                  "permissions": ["allow": ["mcp__pencil"]], "model": "opus"]
            try? jsonData(existing).write(to: URL(fileURLWithPath: settingsPath))
            try? Integrations.installClaudeHooks()
            try? Integrations.installClaudeHooks()
            let s = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath))).flatMap { parseJSON($0) as? JSON } ?? [:]
            let hooks = s["hooks"] as? JSON ?? [:]
            func ours(_ ev: String) -> Int {
                ((hooks[ev] as? [JSON]) ?? []).flatMap { ($0["hooks"] as? [JSON]) ?? [] }.filter { $0.s("command").contains("agentboard-hook") }.count
            }
            let events = Integrations.claudeEvents.map(\.event)
            check(events.allSatisfy { ours($0) == 1 }, "every hook event installed exactly once (installed twice)")
            let herdr = ((hooks["SessionStart"] as? [JSON]) ?? []).flatMap { ($0["hooks"] as? [JSON]) ?? [] }.contains { $0.s("command") == "bash herdr.sh session" }
            check(herdr && s.s("model") == "opus", "other hooks and settings are preserved")
            let allow = ((s["permissions"] as? JSON)?["allow"] as? [String]) ?? []
            check(allow.filter { $0 == "mcp__agentboard" }.count == 1 && allow.contains("mcp__pencil"), "allow rule added once, others kept")
            let backups = (try? FileManager.default.contentsOfDirectory(atPath: claudeDir))?.filter { $0.contains("agentboard-backup") } ?? []
            check(!backups.isEmpty, "a backup is written before changing settings")
            try? Integrations.uninstallClaudeHooks()
            let after = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath))).flatMap { parseJSON($0) as? JSON } ?? [:]
            let left = ((after["hooks"] as? JSON) ?? [:]).values.compactMap { $0 as? [JSON] }.flatMap { $0 }.flatMap { ($0["hooks"] as? [JSON]) ?? [] }
            check(!left.contains { $0.s("command").contains("agentboard-hook") } && left.contains { $0.s("command") == "bash herdr.sh session" },
                  "uninstall removes only AgentBoard's hooks")
        }
        if Integrations.codexHooks.hasPrefix(codexDir + "/") {
            try? FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
            try? jsonData(["hooks": ["Stop": [["hooks": [["type": "command", "command": "my-stop.sh"]]]]]]).write(to: URL(fileURLWithPath: Integrations.codexHooks))
            try? "model = \"gpt-5\"\n".write(toFile: Integrations.codexConfig, atomically: true, encoding: .utf8)
            try? Integrations.installCodexHooks()
            try? Integrations.installCodexHooks()
            let h = (try? Data(contentsOf: URL(fileURLWithPath: Integrations.codexHooks))).flatMap { parseJSON($0) as? JSON }?["hooks"] as? JSON ?? [:]
            let stop = ((h["Stop"] as? [JSON]) ?? []).flatMap { ($0["hooks"] as? [JSON]) ?? [] }
            check(stop.filter { $0.s("command").contains("codex-hook") }.count == 1 && stop.contains { $0.s("command") == "my-stop.sh" },
                  "Codex hooks installed once, existing hooks kept")
        }

        section("Git hooks")
        let hooksDir = Integrations.gitHooksDir(project) ?? ""
        try? "#!/bin/sh\nexec ./run-linters\n".write(toFile: hooksDir + "/pre-commit", atomically: true, encoding: .utf8)
        try? Integrations.installGitHook(project)
        try? Integrations.installGitHook(project)
        let pre = (try? String(contentsOfFile: hooksDir + "/pre-commit")) ?? ""
        let preLines = pre.components(separatedBy: "\n")
        check(preLines.count > 2 && preLines[1].contains("agentboard-hook") && preLines[1].contains("git-pre-commit"),
              "pre-commit guard sits right after the shebang (before an existing exec)", preLines.prefix(3).joined(separator: " | "))
        check(preLines.filter { $0.contains("git-pre-commit") }.count == 1 && pre.contains("exec ./run-linters"), "installed once, existing hook kept")
        check(Integrations.gitHookInstalled(project), "installed state detected")
        // Leave a hook that git can actually run for the end-to-end check below.
        try? "#!/bin/sh\n".write(toFile: hooksDir + "/pre-commit", atomically: true, encoding: .utf8)
        try? Integrations.installGitHook(project)

        section("End to end through the bridge: real git commit vs a reservation")
        // A real HTTP server on a spare port, the real bridge script, a real `git commit`.
        var server: HTTPServer?
        var port = 0
        for p in 27_700..<27_760 {
            let s = HTTPServer(port: p) { req, reply in core.q.async { core.route(req, reply) } }
            if (try? s.start()) != nil { server = s; port = p; break }
        }
        check(server != nil, "test server listening")
        Integrations.writeBridge()
        try? "\(port)".write(toFile: Integrations.baseDir + "/port", atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.3)
        let gitEnv = ["AGENTBOARD_INTERNAL": ""]  // the bridge is a no-op for the app's own children otherwise
        _ = hook(["hook_event_name": "SessionStart", "session_id": "e2e", "cwd": repo, "source": "startup"])
        let holder = core.q.sync { core.db.query("SELECT * FROM agents WHERE session_id='sA'").first.map(Agent.init) }!
        _ = core.q.sync { core.reserve(agent: holder, patterns: ["src/auth/"], minutes: 30, exclusive: true, reason: "e2e") }
        try? "changed by e2e\n".write(toFile: repo + "/src/auth/login.ts", atomically: true, encoding: .utf8)
        _ = Shell.run("/usr/bin/git", ["add", "-A"], cwd: repo)
        _ = hook(["hook_event_name": "PreToolUse", "session_id": "e2e", "cwd": repo, "tool_name": "Bash", "tool_input": ["command": "git commit -m e2e"]])
        let blocked = Shell.run("/usr/bin/git", ["commit", "-m", "agent commit"], cwd: repo, env: gitEnv, timeout: 30)
        check(!blocked.ok && blocked.err.contains("reserved"), "an agent's commit touching another agent's reservation is refused by git",
              "exit \(blocked.code): \(blocked.err.oneLine.trunc(200))")
        core.q.sync { core.commitIntent.removeAll() }
        let human = Shell.run("/usr/bin/git", ["commit", "-m", "human commit"], cwd: repo, env: gitEnv, timeout: 30)
        check(human.ok, "the human's own commit goes through", human.err.oneLine.trunc(200))
        let head = Shell.git(["rev-parse", "HEAD"], cwd: repo).line
        var recorded = false
        for _ in 0..<60 where !recorded {
            recorded = core.q.sync { !core.db.query("SELECT 1 FROM events WHERE kind='commit' AND ref=?", [head]).isEmpty }
            if !recorded { Thread.sleep(forTimeInterval: 0.1) }
        }
        check(recorded, "post-commit hook reports the commit to the board")
        server?.stop()
    }
}

extension SelfTest {
    /// Risky paths the coverage report showed as never run: liveness, MCP tool rules, delivery, summary input.
    static func gapSuite(core: Core, project: Project, repo: String, root: String) {
        func hook(_ j: JSON) -> JSON? {
            var out: Data?
            core.q.sync { core.handleClaudeHook(j) { out = $0 } }
            return out.flatMap { parseJSON($0) as? JSON }
        }
        func agentRow(_ sid: String) -> Agent? {
            core.q.sync { core.db.query("SELECT * FROM agents WHERE session_id=?", [sid]).first.map(Agent.init) }
        }
        func tool(_ name: String, _ args: JSON) -> (text: String, error: Bool) {
            let out = core.q.sync { core.handleMCP(jsonData(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])) }
            let r = (out.flatMap { parseJSON($0) as? JSON }?["result"] as? JSON) ?? [:]
            return (((r["content"] as? [JSON])?.first?.s("text")) ?? "", r["isError"] as? Bool ?? false)
        }

        section("Session liveness")
        let sessions = root + "/claude/sessions"
        try? FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
        let me = getpid()
        let utcStart = Shell.run("/bin/ps", ["-o", "lstart=", "-p", "\(me)"], env: ["LC_ALL": "C", "TZ": "UTC"]).out.trimmed
        check(SessionLiveness.isAlive(pid: me, procStart: utcStart), "a live process with its UTC start time is alive", utcStart)
        check(!SessionLiveness.isAlive(pid: me, procStart: "Sat Jan  1 00:00:00 2000"), "a reused pid (different start time) is not trusted")
        check(!SessionLiveness.isAlive(pid: 999_999, procStart: ""), "a dead pid is not alive")
        for sid in ["live1", "dead1", "idle1"] { _ = hook(["hook_event_name": "SessionStart", "session_id": sid, "cwd": repo, "source": "startup"]) }
        let live1 = agentRow("live1")!, idle1 = agentRow("idle1")!
        _ = core.q.sync { core.reserve(agent: live1, patterns: ["docs/"], minutes: 30, exclusive: true, reason: "") }
        core.q.sync {
            core.db.query("UPDATE agents SET last_seen=? WHERE session_id IN ('live1','dead1')", [now() - 500])
            core.db.query("UPDATE agents SET status='working', last_action_at=? WHERE session_id='idle1'", [now() - 120])
        }
        func writeSession(_ name: String, _ j: JSON) { try? jsonData(j).write(to: URL(fileURLWithPath: sessions + "/" + name)) }
        writeSession("\(me).json", ["pid": me, "sessionId": "live1", "procStart": utcStart, "status": "busy"])
        writeSession("999999.json", ["pid": 999_999, "sessionId": "dead1", "procStart": "Sat Jan  1 00:00:00 2000", "status": "busy"])
        writeSession("idle.json", ["pid": me, "sessionId": "idle1", "procStart": utcStart, "status": "idle", "statusUpdatedAt": (now() - 120) * 1000])
        SessionLiveness.shared.tick(); core.q.sync {}
        check(now() - (agentRow("live1")?.lastSeen ?? 0) < 10, "an open session is kept active")
        check(agentRow("dead1")?.status != "ended", "a session never seen alive is not ended (no false 'closed')")
        check(agentRow("idle1")?.status == "idle", "a missed Stop is corrected from the session file", agentRow("idle1")?.status ?? "nil")
        try? FileManager.default.removeItem(atPath: sessions + "/\(me).json")
        core.q.sync { _ = core.db.query("UPDATE agents SET last_seen=? WHERE id=?", [now() - 100, live1.id]) }
        SessionLiveness.shared.tick(); core.q.sync {}
        check(agentRow("live1")?.status == "ended", "a session seen alive whose process is gone is ended")
        check(core.q.sync { core.activeReservations(project: project.id).filter { $0.agentId == live1.id }.isEmpty },
              "its reservations are released")
        try? FileManager.default.removeItem(atPath: sessions)
        _ = idle1

        section("MCP tool rules")
        for sid in ["mx", "my"] { _ = hook(["hook_event_name": "SessionStart", "session_id": sid, "cwd": repo, "source": "startup"]) }
        let mx = agentRow("mx")!, my = agentRow("my")!
        let t = core.q.sync { core.createTask(project: project.id, title: "Shared task", details: "", client: "", status: .backlog, assignee: nil, createdBy: "user") }
        check(!tool("claim_task", ["agent_id": mx.id, "task_id": t.id]).error, "an agent claims a free task")
        check(core.q.sync { core.task(id: t.id)?.status } == .in_progress, "claiming a backlog task starts it")
        check(tool("claim_task", ["agent_id": my.id, "task_id": t.id]).error, "a task held by another active agent can't be claimed")
        check(!tool("claim_task", ["agent_id": my.id, "task_id": t.id, "force": true]).error
              && core.q.sync { core.task(id: t.id)?.assignee } == my.id, "force takes it over")
        _ = tool("update_task", ["agent_id": my.id, "task_id": t.id, "status": "review", "note": "done, run tests"])
        check(core.q.sync { core.task(id: t.id)?.status } == .review, "update_task changes the status")
        check(tool("update_task", ["agent_id": my.id, "task_id": t.id, "status": "finished"]).error, "an unknown status is rejected")
        let before = core.q.sync { core.db.query("SELECT COUNT(*) AS n FROM messages WHERE to_agent=?", [mx.id]).first?.i("n") ?? 0 }
        _ = tool("send_message", ["agent_id": my.id, "to": "all", "text": "heads up: schema changed"])
        let after = core.q.sync { core.db.query("SELECT COUNT(*) AS n FROM messages WHERE to_agent=?", [mx.id]).first?.i("n") ?? 0 }
        let toSelf = core.q.sync { core.db.query("SELECT COUNT(*) AS n FROM messages WHERE to_agent=? AND text LIKE 'heads up%'", [my.id]).first?.i("n") ?? 0 }
        check(after == before + 1 && toSelf == 0, "a broadcast reaches the others, not the sender")
        let ctx = (hook(["hook_event_name": "PostToolUse", "session_id": "mx", "cwd": repo, "tool_name": "Read", "tool_input": ["file_path": repo + "/a.txt"]])?["hookSpecificOutput"] as? JSON)?.s("additionalContext") ?? ""
        check(ctx.contains("heads up: schema changed"), "the message arrives in the recipient's context at its next step")
        let again = (hook(["hook_event_name": "PostToolUse", "session_id": "mx", "cwd": repo, "tool_name": "Read", "tool_input": ["file_path": repo + "/a.txt"]])?["hookSpecificOutput"] as? JSON)?.s("additionalContext") ?? ""
        check(!again.contains("heads up"), "a delivered message is not delivered twice")
        check(tool("send_message", ["agent_id": my.id, "to": "Nobody-Here", "text": "x"]).error, "message to an unknown agent is an error")
        let reg = tool("register_agent", ["cwd": repo, "tool": "cursor"])
        check(!reg.error && reg.text.contains("agent_id"), "a client without hooks can register", reg.text.trunc(80))
        check(tool("register_agent", ["cwd": "/definitely/not/a/project"]).error, "registering outside known projects is refused")

        section("Delivering a human message into a session")
        _ = hook(["hook_event_name": "UserPromptSubmit", "session_id": "mx", "cwd": repo, "prompt": "Refactor the parser please"])
        let r = SessionDelivery.run(agentId: mx.id, text: "also update the docs", mode: .auto)
        check(r.lowercased().contains("next step") || r.lowercased().contains("queue"), "a working agent gets it in context, not typed into a terminal", r)
        let ctx2 = (hook(["hook_event_name": "PostToolUse", "session_id": "mx", "cwd": repo, "tool_name": "Read", "tool_input": ["file_path": repo + "/a.txt"]])?["hookSpecificOutput"] as? JSON)?.s("additionalContext") ?? ""
        check(ctx2.contains("also update the docs"), "…and it arrives at the agent's next step")
        let noTerm = SessionDelivery.run(agentId: mx.id, text: "x", mode: .terminal)
        check(!noTerm.lowercased().contains("sent to"), "without a known terminal nothing is typed anywhere", noTerm)

        section("Inputs for the model-written texts")
        core.q.sync {
            core.db.update("agents", id: mx.id, ["last_prompt": "<pasted_content id=\"1\">fix the parser</pasted_content>"])
            core.addEvent(project: project.id, agent: mx.id, kind: "action", title: "first step", at: now() - 50)
            core.addEvent(project: project.id, agent: mx.id, kind: "action", title: "second step", at: now() - 10)
        }
        let narr = core.q.sync { Narrator.context(core, core.agent(id: mx.id)!) }
        check(narr.contains("fix the parser") && !narr.contains("<pasted_content"), "narrator sees the request without markup")
        if let a = narr.range(of: "first step"), let b = narr.range(of: "second step") {
            check(a.lowerBound < b.lowerBound, "narrator gets actions oldest first")
        } else { check(false, "narrator gets the recent actions") }
        let collected = SummaryService.collect(day: Date())
        check(collected.hasActivity && collected.text.contains("=== PROJECT: \(project.name)") && collected.text.contains("=== TIME ==="),
              "summary input has the project section and the time section")
        check(collected.text.contains("human commit"), "summary input includes today's commits")
        let rows = core.q.sync { core.db.query("SELECT * FROM events WHERE project_id=? ORDER BY created_at", [project.id]).map(EventItem.init) }
        let fb = AwayWatcher.fallback(rows, [project.id: project.name])
        let bullets = fb.split(separator: "\n")
        check(bullets.count <= 8 && bullets.allSatisfy { $0.hasPrefix("• ") } && !fb.contains("first step"),
              "away fallback lists at most 8 important events, no routine actions")
    }
}
