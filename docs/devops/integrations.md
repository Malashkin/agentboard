---
audience: devops
owner: @Malashkin
updated: 2026-11-09
---

# Integrations

| Target | What is written | Installer |
|---|---|---|
| `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude/settings.json`) | Hooks for SessionStart, UserPromptSubmit, PreToolUse(*), PermissionRequest(*), PostToolUse(*), PostToolUseFailure(*), SubagentStart, SubagentStop, Notification, Stop, SessionEnd → `agentboard-hook claude`; `permissions.allow += "mcp__agentboard"` | `installClaudeHooks` |
| Claude Code MCP | `claude mcp add --scope user --transport http agentboard http://127.0.0.1:7777/mcp` | `installClaudeMCP` |
| `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`) | `[mcp_servers.agentboard] url = …`; `notify = [bridge, "codex"]` if no notify exists | `installCodex` |
| `$CODEX_HOME/hooks.json` | Codex hooks → `agentboard-hook codex-hook` (Codex asks once to trust them) | `installCodexHooks` |
| Project git hooks (`git rev-parse --git-path hooks`) | `pre-commit` (after shebang) and `post-commit` lines calling the bridge | `installGitHook` (on add + every launch) |
| Project `AGENTS.md` (optional) | Rules block between `agentboard:start` / `agentboard:end` markers | project settings |

Paths follow `CLAUDE_CONFIG_DIR` / `CODEX_HOME` exactly like Claude Code and Codex do, so an isolated run
(`CLAUDE_CONFIG_DIR=/tmp/x AgentBoard --install-claude`) never touches your real configuration.

Every installer backs up the file first (`*.agentboard-backup-<date>-<ts>`) and touches only entries
containing `agentboard-hook` or `mcp__agentboard`; other hooks (e.g. herdr) are preserved.
