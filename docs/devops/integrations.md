---
audience: devops
owner: @Malashkin
updated: 2026-11-11
---

# Integrations

| Target | What is written | Installer |
|---|---|---|
| `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude/settings.json`) | Hooks for SessionStart, UserPromptSubmit, PreToolUse(*), PermissionRequest(*), PostToolUse(*), PostToolUseFailure(*), SubagentStart, SubagentStop, Notification, Stop, SessionEnd → `agentboard-hook claude`; `permissions.allow += "mcp__agentboard"` | `installClaudeHooks` |
| Claude Code MCP | `claude mcp add --scope user --transport http agentboard http://127.0.0.1:7777/mcp --header "Authorization: Bearer <token>"` | `installClaudeMCP` |
| `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`) | `[mcp_servers.agentboard] url = …`, `http_headers = { Authorization = "Bearer <token>" }` (file made 0600); `notify = [bridge, "codex"]` if no notify exists | `installCodex` |
| `~/.gemini/settings.json` (`$GEMINI_CLI_HOME/.gemini` when set) | Hooks SessionStart, BeforeAgent, BeforeTool(`.*`), AfterTool(`.*`), AfterAgent, Notification, SessionEnd → `agentboard-hook gemini` (timeouts in ms); `mcpServers.agentboard = {httpUrl, headers.Authorization, trust}`; file made 0600 | `installGemini` / `uninstallGemini`, `--install-gemini` |
| `~/.agentboard/telegram.json` | Bot token, paired chat id, "only when away" (0600) — only after the human pairs a bot | Settings → Phone |
| `~/.agentboard/token`, `~/.agentboard/auth-header` | Per-install secret (0600, folder 0700); the bridge sends it with `curl -H @auth-header` | `Auth` (first launch) |
| `$CODEX_HOME/hooks.json` | Codex hooks → `agentboard-hook codex-hook` (Codex asks once to trust them) | `installCodexHooks` |
| Project git hooks (`git rev-parse --git-path hooks`) | `pre-commit` (after shebang) and `post-commit` lines calling the bridge | `installGitHook` (on add + every launch) |
| Project `AGENTS.md` (optional) | Rules block between `agentboard:start` / `agentboard:end` markers | project settings |

Paths follow `CLAUDE_CONFIG_DIR` / `CODEX_HOME` exactly like Claude Code and Codex do, so an isolated run
(`CLAUDE_CONFIG_DIR=/tmp/x AgentBoard --install-claude`) never touches your real configuration.

At each launch `refreshMCPRegistrations` re-registers Claude Code / Codex MCP if the URL or token in their
config is stale, so a new token or port reaches agents without a manual *Connect* (running sessions must restart).

**Automation (Apple Events).** Typing into a terminal and the *Terminal* button run AppleScript inside the app
against iTerm2 / Terminal.app; `Info.plist` carries `NSAppleEventsUsageDescription`, so macOS asks once per
target app (System Settings → Privacy & Security → Automation). Ad-hoc signed builds may be asked again after
a rebuild; `tccutil reset AppleEvents app.agentboard.mac` clears a stale refusal.

Every installer backs up the file first (`*.agentboard-backup-<date>-<ts>`) and touches only entries
containing `agentboard-hook` or `mcp__agentboard`; other hooks (e.g. herdr) are preserved.
