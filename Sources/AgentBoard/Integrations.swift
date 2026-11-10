import Foundation

/// Installs the bridges between agents and AgentBoard: hook script, Claude Code hooks + MCP, Codex, git hooks.
enum Integrations {
    static let home = NSHomeDirectory()
    static let baseDir = ProcessInfo.processInfo.environment["AGENTBOARD_BRIDGE_DIR"] ?? (home + "/.agentboard")
    static let hookPath = baseDir + "/bin/agentboard-hook"
    static let marker = "agentboard-hook"
    static var mcpURL: String { "http://127.0.0.1:\(AppSettings.port)/mcp" }
    /// Claude Code / Codex folders honour CLAUDE_CONFIG_DIR / CODEX_HOME, like the tools themselves —
    /// so an isolated run never edits the real ~/.claude or ~/.codex.
    static var claudeDir: String { env("CLAUDE_CONFIG_DIR") ?? home + "/.claude" }
    static var codexDir: String { env("CODEX_HOME") ?? home + "/.codex" }
    static var claudeSettings: String { claudeDir + "/settings.json" }
    static var codexConfig: String { codexDir + "/config.toml" }
    private static func env(_ k: String) -> String? {
        ProcessInfo.processInfo.environment[k].flatMap { $0.isEmpty ? nil : $0 }
    }

    static let hookScript = """
    #!/bin/bash
    # AgentBoard bridge: forwards agent and git events to the AgentBoard app on 127.0.0.1.
    # Never blocks or breaks the agent: if the app isn't running, it exits silently.
    [ -n "$AGENTBOARD_INTERNAL" ] && exit 0
    # The port file sits next to bin/ (AGENTBOARD_BRIDGE_DIR, default ~/.agentboard).
    BASE=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
    PORT=$(cat "$BASE/port" 2>/dev/null || echo 7777)
    URL="http://127.0.0.1:$PORT"
    # The install's token, as a ready header line (0600 file; read by curl so it never appears in `ps`).
    AUTH="$BASE/auth-header"
    case "$1" in
      claude)
        # stdin: hook JSON from Claude Code; stdout: optional hook response JSON.
        # The controlling terminal lets AgentBoard type comments into this session's tab.
        TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
        curl -sf -H @"$AUTH" --connect-timeout 1 --max-time 3700 -X POST -H 'Content-Type: application/json' \\
          --data-binary @- "$URL/hook/claude?tty=$TTY" 2>/dev/null
        ;;
      codex-hook)
        # Codex hooks (~/.codex/hooks.json) use Claude Code's format: same handler, marked as Codex.
        TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
        curl -sf -H @"$AUTH" --connect-timeout 1 --max-time 3700 -X POST -H 'Content-Type: application/json' \\
          --data-binary @- "$URL/hook/claude?tool=codex&tty=$TTY" 2>/dev/null
        ;;
      codex)
        # Codex `notify` passes the event JSON as the last argument.
        printf '%s' "${@: -1}" | curl -sf -H @"$AUTH" --connect-timeout 1 --max-time 5 -X POST \\
          -H 'Content-Type: application/json' --data-binary @- "$URL/hook/codex" >/dev/null 2>&1
        ;;
      git-pre-commit)
        # Refuses a commit by an agent that touches files another agent has reserved.
        top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
        files=$(git diff --cached --name-only 2>/dev/null)
        [ -z "$files" ] && exit 0
        resp=$( { printf '%s\n' "$top"; printf '%s\n' "$files"; } | curl -sf -H @"$AUTH" --connect-timeout 1 --max-time 5 -X POST \\
          -H 'Content-Type: application/octet-stream' --data-binary @- "$URL/hook/git-precommit" 2>/dev/null)
        if [ -n "$resp" ]; then printf '%s\n' "$resp" >&2; exit 1; fi
        ;;
      git-post-commit)
        top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
        hash=$(git rev-parse HEAD 2>/dev/null) || exit 0
        esc() { printf '%s' "$1" | sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g'; }
        body=$(printf '{"cwd":"%s","hash":"%s"}' "$(esc "$top")" "$hash")
        ( printf '%s' "$body" | curl -sf -H @"$AUTH" --connect-timeout 1 --max-time 5 -X POST \\
            -H 'Content-Type: application/json' --data-binary @- "$URL/hook/git" >/dev/null 2>&1 & )
        ;;
    esac
    exit 0

    """

    /// Called at launch: keeps the script and the port file current.
    static func writeBridge() {
        let fm = FileManager.default
        Auth.secureBaseDir()
        _ = Auth.token   // creates token + auth-header on first launch
        try? fm.createDirectory(atPath: baseDir + "/bin", withIntermediateDirectories: true)
        try? hookScript.write(toFile: hookPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
        try? "\(AppSettings.port)".write(toFile: baseDir + "/port", atomically: true, encoding: .utf8)
    }

    // MARK: Claude Code hooks

    static var claudeEvents: [(event: String, matcher: String?, timeout: Int)] {
        [("SessionStart", nil, 10),
         ("UserPromptSubmit", nil, 10),
         ("PreToolUse", "*", Int(AppSettings.approvalTimeout) + 30),
         ("PermissionRequest", "*", Int(AppSettings.permissionTimeout) + 30),
         ("PostToolUse", "*", 5),
         ("PostToolUseFailure", "*", 5),
         ("SubagentStart", nil, 5),
         ("SubagentStop", nil, 5),
         ("Notification", nil, 10),
         ("Stop", nil, 10),
         ("SessionEnd", nil, 10)]
    }

    private static func readJSON(_ path: String) -> JSON? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return parseJSON(d) as? JSON
    }

    private static func writeJSON(_ obj: JSON, _ path: String) throws {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func backup(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let stamp = Fmt.dayKey.string(from: Date()) + "-" + String(Int(now()))
        try? FileManager.default.copyItem(atPath: path, toPath: path + ".agentboard-backup-" + stamp)
    }

    static func claudeHooksInstalled() -> Bool {
        guard let s = readJSON(claudeSettings), let hooks = s["hooks"] as? JSON else { return false }
        return claudeEvents.allSatisfy { ev in
            ((hooks[ev.event] as? [JSON]) ?? []).contains { group in
                ((group["hooks"] as? [JSON]) ?? []).contains { $0.s("command").contains(marker) }
            }
        }
    }

    private static func strippedHooks(_ hooks: JSON) -> JSON {
        var out = hooks
        for (event, value) in hooks {
            guard let groups = value as? [JSON] else { continue }
            let kept = groups.compactMap { g -> JSON? in
                var g = g
                let hs = ((g["hooks"] as? [JSON]) ?? []).filter { !$0.s("command").contains(marker) }
                if hs.isEmpty { return nil }
                g["hooks"] = hs
                return g
            }
            if kept.isEmpty { out.removeValue(forKey: event) } else { out[event] = kept }
        }
        return out
    }

    static func installClaudeHooks() throws {
        writeBridge()
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: claudeSettings) && readJSON(claudeSettings) == nil {
            throw NSError(domain: "AgentBoard", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "~/.claude/settings.json contains invalid JSON — fix it manually and try again"])
        }
        backup(claudeSettings)
        var s = readJSON(claudeSettings) ?? [:]
        var hooks = strippedHooks(s["hooks"] as? JSON ?? [:])
        for ev in claudeEvents {
            var group: JSON = ["hooks": [["type": "command", "command": "\(hookPath) claude", "timeout": ev.timeout]]]
            if let m = ev.matcher { group["matcher"] = m }
            hooks[ev.event] = ((hooks[ev.event] as? [JSON]) ?? []) + [group]
        }
        s["hooks"] = hooks
        // Let agents use the board without a permission prompt for every call.
        var perms = s["permissions"] as? JSON ?? [:]
        var allow = perms["allow"] as? [String] ?? []
        if !allow.contains("mcp__agentboard") { allow.append("mcp__agentboard") }
        perms["allow"] = allow
        s["permissions"] = perms
        try writeJSON(s, claudeSettings)
    }

    static func uninstallClaudeHooks() throws {
        guard var s = readJSON(claudeSettings) else { return }
        backup(claudeSettings)
        let hooks = strippedHooks(s["hooks"] as? JSON ?? [:])
        if hooks.isEmpty { s.removeValue(forKey: "hooks") } else { s["hooks"] = hooks }
        try writeJSON(s, claudeSettings)
    }

    // MARK: Claude Code MCP

    /// Claude Code keeps user-scope MCP servers in ~/.claude.json (inside CLAUDE_CONFIG_DIR when that is set).
    static var claudeJSON: String { env("CLAUDE_CONFIG_DIR").map { $0 + "/.claude.json" } ?? home + "/.claude.json" }
    static var bearer: String { "Bearer " + Auth.token }

    private static var claudeMCPEntry: JSON? {
        (readJSON(claudeJSON)?["mcpServers"] as? JSON)?["agentboard"] as? JSON
    }

    /// Registered, with the current URL and token.
    static func claudeMCPInstalled() -> Bool {
        guard let e = claudeMCPEntry else { return false }
        return e.s("url") == mcpURL && (e["headers"] as? JSON)?.s("Authorization") == bearer
    }

    /// Registered by an older version (no token) or for another port: re-register at launch so MCP keeps working.
    static func claudeMCPNeedsRefresh() -> Bool { claudeMCPEntry != nil && !claudeMCPInstalled() }

    static func installClaudeMCP() throws {
        guard let claude = Shell.which("claude") else {
            throw NSError(domain: "AgentBoard", code: 3, userInfo: [NSLocalizedDescriptionKey: "claude CLI not found"])
        }
        _ = Shell.run(claude, ["mcp", "remove", "--scope", "user", "agentboard"], timeout: 30)
        let r = Shell.run(claude, ["mcp", "add", "--scope", "user", "--transport", "http", "agentboard", mcpURL,
                                    "--header", "Authorization: " + bearer], timeout: 30)
        if !r.ok {
            throw NSError(domain: "AgentBoard", code: 4, userInfo: [NSLocalizedDescriptionKey: "claude mcp add: " + (r.err.isEmpty ? r.out : r.err)])
        }
    }

    static func uninstallClaudeMCP() {
        if let claude = Shell.which("claude") {
            _ = Shell.run(claude, ["mcp", "remove", "--scope", "user", "agentboard"], timeout: 30)
        }
    }

    // MARK: Codex

    static var codexAvailable: Bool {
        Shell.which("codex") != nil || FileManager.default.fileExists(atPath: codexDir)
    }

    static func codexInstalled() -> Bool {
        guard let t = try? String(contentsOfFile: codexConfig) else { return false }
        return t.contains(codexMCPSection) && codexHooksInstalled()
    }

    static func codexMCPNeedsRefresh() -> Bool {
        guard let t = try? String(contentsOfFile: codexConfig) else { return false }
        return t.contains("[mcp_servers.agentboard]") && !t.contains(codexMCPSection)
    }

    /// The MCP entry with the install's token (Codex sends `http_headers` on every request).
    static var codexMCPSection: String {
        "[mcp_servers.agentboard]\nurl = \"\(mcpURL)\"\nhttp_headers = { Authorization = \"\(bearer)\" }\n"
    }

    /// Replaces our [mcp_servers.agentboard] table (up to the next table header) and keeps everything else.
    static func withCodexMCPSection(_ text: String) -> String {
        var out: [String] = [], skipping = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[mcp_servers.agentboard]" { skipping = true; continue }
            if skipping && t.hasPrefix("[") { skipping = false }
            if !skipping { out.append(line) }
        }
        var kept = out.joined(separator: "\n")
        while kept.hasSuffix("\n\n") { kept.removeLast() }
        return kept + (kept.isEmpty ? "" : (kept.hasSuffix("\n") ? "\n" : "\n\n")) + codexMCPSection
    }

    /// Called at launch: older installs registered MCP without the token.
    /// Started with its own data or bridge folder (self-test, UI snapshots, a second copy): must leave the real
    /// ~/.claude.json, ~/.codex/config.toml and project git hooks alone.
    static var isSideInstance: Bool {
        let env = ProcessInfo.processInfo.environment
        return ["AGENTBOARD_DATA_DIR", "AGENTBOARD_BRIDGE_DIR"].contains { !(env[$0] ?? "").isEmpty }
    }

    static func refreshMCPRegistrations() {
        if claudeMCPNeedsRefresh() { try? installClaudeMCP() }
        if codexMCPNeedsRefresh() {
            backup(codexConfig)
            if let t = try? String(contentsOfFile: codexConfig) { writeCodexConfig(withCodexMCPSection(t)) }
        }
    }

    /// config.toml now holds the token: owner-only.
    private static func writeCodexConfig(_ text: String) {
        try? text.write(toFile: codexConfig, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codexConfig)
    }

    static var codexHooks: String { codexDir + "/hooks.json" }

    /// Codex hooks: live actions, permission requests answered from the app, reservations enforced on patches.
    /// Codex asks once to trust new hooks ("Hooks need review") — choose to trust them.
    static func installCodexHooks() throws {
        if FileManager.default.fileExists(atPath: codexHooks) && readJSON(codexHooks) == nil {
            throw NSError(domain: "AgentBoard", code: 3, userInfo: [NSLocalizedDescriptionKey: "~/.codex/hooks.json is not valid JSON — fix it and retry"])
        }
        backup(codexHooks)
        var s = readJSON(codexHooks) ?? [:]
        var hooks = strippedHooks(s["hooks"] as? JSON ?? [:])
        let events: [(String, Int)] = [("SessionStart", 10), ("UserPromptSubmit", 10), ("PreToolUse", Int(AppSettings.approvalTimeout) + 30),
                                       ("PermissionRequest", Int(AppSettings.permissionTimeout) + 30), ("PostToolUse", 5),
                                       ("Stop", 10), ("SubagentStart", 5), ("SubagentStop", 5), ("SessionEnd", 3)]
        for (ev, timeout) in events {
            let group: JSON = ["hooks": [["type": "command", "command": "\(hookPath) codex-hook", "timeout": timeout]]]
            hooks[ev] = ((hooks[ev] as? [JSON]) ?? []) + [group]
        }
        s["hooks"] = hooks
        try writeJSON(s, codexHooks)
    }

    static func codexHooksInstalled() -> Bool {
        guard let s = readJSON(codexHooks), let hooks = s["hooks"] as? JSON else { return false }
        return ((hooks["PreToolUse"] as? [JSON]) ?? []).contains { g in ((g["hooks"] as? [JSON]) ?? []).contains { $0.s("command").contains(marker) } }
    }

    static func installCodex() throws {
        try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        try installCodexHooks()
        backup(codexConfig)
        var text = withCodexMCPSection((try? String(contentsOfFile: codexConfig)) ?? "")
        // `notify` is a top-level key; only add it when the user doesn't already have one.
        let hasNotify = text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }
        if !hasNotify {
            text = "notify = [\"\(hookPath)\", \"codex\"]\n" + text
        }
        try text.write(toFile: codexConfig, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codexConfig)
    }

    // MARK: Git hooks (per project)

    static func gitHooksDir(_ project: Project) -> String? {
        let r = Shell.git(["rev-parse", "--path-format=absolute", "--git-path", "hooks"], cwd: project.path)
        return r.ok ? r.line : nil
    }

    static func gitHookInstalled(_ project: Project) -> Bool {
        guard let dir = gitHooksDir(project), let t = try? String(contentsOfFile: dir + "/post-commit") else { return false }
        let pre = (try? String(contentsOfFile: dir + "/pre-commit")) ?? ""
        return t.contains(marker) && pre.contains(marker)
    }

    static func installGitHook(_ project: Project) throws {
        writeBridge()
        guard let dir = gitHooksDir(project) else {
            throw NSError(domain: "AgentBoard", code: 5, userInfo: [NSLocalizedDescriptionKey: "This is not a git repository"])
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/post-commit"
        let line = "\"\(hookPath)\" git-post-commit # agentboard-hook"
        var text = (try? String(contentsOfFile: path)) ?? "#!/bin/sh\n"
        if !text.contains(marker) {
            text += (text.hasSuffix("\n") ? "" : "\n") + line + "\n"
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        // pre-commit: right after the shebang, so an `exec` at the end of an existing hook can't skip it.
        let prePath = dir + "/pre-commit"
        let preLine = "\"\(hookPath)\" git-pre-commit || exit 1 # agentboard-hook"
        var pre = (try? String(contentsOfFile: prePath)) ?? "#!/bin/sh\n"
        if !pre.contains(marker) {
            var lines = pre.components(separatedBy: "\n")
            let at = lines.first?.hasPrefix("#!") == true ? 1 : 0
            if at == 0 { lines.insert("#!/bin/sh", at: 0) }
            lines.insert(preLine, at: 1)
            pre = lines.joined(separator: "\n")
            if !pre.hasSuffix("\n") { pre += "\n" }
        }
        try pre.write(toFile: prePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prePath)
    }

    static func uninstallGitHook(_ project: Project) {
        guard let dir = gitHooksDir(project) else { return }
        for name in ["post-commit", "pre-commit"] {
            let path = dir + "/" + name
            guard let text = try? String(contentsOfFile: path) else { continue }
            let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(marker) }.joined(separator: "\n")
            try? kept.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: AGENTS.md (for Codex and other tools without hooks)

    static let agentsSnippet = """
    <!-- agentboard:start -->
    ## AgentBoard: multiple agents at work

    Several agents work on this project at the same time; the human sees everything in the AgentBoard app.
    Use the `agentboard` MCP server:
    1. At the start of a session call `register_agent(cwd)` (Claude Code registers automatically) and pass `agent_id` in every call.
    2. `board` — who is doing what; `agent_activity(agent)` — details about a specific agent.
    3. Take a task via `claim_task` / `create_task(claim=true)`, announce your files via `set_focus`.
    4. Don't touch files another agent is editing; coordinate via `send_message`.
    5. When done — `update_task(status="review"|"done", note=...)`. Set `client` if the work is for a client.
    <!-- agentboard:end -->

    """

    static func agentsMdInstalled(_ project: Project) -> Bool {
        ((try? String(contentsOfFile: project.path + "/AGENTS.md")) ?? "").contains("agentboard:start")
    }

    static func installAgentsMd(_ project: Project) throws {
        let path = project.path + "/AGENTS.md"
        var text = (try? String(contentsOfFile: path)) ?? ""
        guard !text.contains("agentboard:start") else { return }
        text += (text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")) + agentsSnippet
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
