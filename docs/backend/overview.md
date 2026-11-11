---
audience: backend
owner: @Malashkin
updated: 2026-11-11
---

# Backend overview

All sources are in `Sources/AgentBoard/`.

| File | Responsibility |
|---|---|
| `Core.swift` | Database setup and migrations, snapshot for the UI, projects/agents/tasks/events/messages, Claude & Codex hook handler, commit flow, routing, pinning, data retention |
| `Coordination.swift` | Reservations and pre-commit guard, stuck detection, permission/question/plan flow, launched-task claiming, overlap heads-up for paths named in a request |
| `MCPServer.swift` | MCP JSON-RPC: tool definitions and handlers |
| `HTTPServer.swift` | Loopback HTTP/1.1 server (Network.framework), delayed replies; limits: 8 MB request, 256 connections, 30 s to send a request |
| `Auth.swift` | Per-install token (`~/.agentboard/token`), header check, constant-time compare, private (0600) file writes |
| `Integrations.swift` | Bridge script, Claude/Codex/Gemini CLI hooks and MCP registration (paths follow `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `GEMINI_CLI_HOME`), git hooks, AGENTS.md snippet |
| `Gemini.swift` | Gemini CLI events, tools and answers ↔ Claude Code's (`GeminiHooks.toClaude` / `fromClaude`) |
| `Herdr.swift` | herdr panes: find a session's pane, prompt it, focus it |
| `QuickAccess.swift` | `TerminalFocus` (raise the agent's tab), `Attention` (who needs you, in order), global `HotKeys`, the *Needs you* `QuickPanel` |
| `ProjectMemory.swift` | Project memory: `remember` / `forget`, the text given at session start |
| `Handoff.swift` | Briefing on an agent's work and its delivery to another agent |
| `Telegram.swift` | Phone link: `TelegramLink` (pure: messages, buttons, parsing of updates) and the `Telegram` poller/sender |
| `CodexWatcher.swift` | Follows Codex rollout logs (for sessions without hooks) |
| `SessionLiveness.swift` | Reads `~/.claude/sessions/*.json`, verifies processes, marks open/closed sessions, adopts open sessions no hook reported |
| `Narrator.swift` | Plain-language status lines via `claude -p` |
| `AutoTasks.swift` | Task autopilot and time report |
| `AwayDigest.swift` | "While you were away" |
| `SessionDelivery.swift` | Messages into sessions: inbox, terminal typing, background resume; the agent's tty; in-process AppleScript (`osa`) |
| `Workspaces.swift` | Task worktrees, terminal launch, diff/merge/PR, diff parser |
| `HistoryImporter.swift` | Imports past Claude/Codex sessions and git commits |
| `ProjectDiscovery.swift` | Suggests folders agents worked in (last 60 days) that aren't on the board: reads `cwd` from session files, rolls up to the git top level / main checkout, drops known, removed, ignored, excluded (`~`, `~/Desktop`, `~/Library`, temp, hidden) and container folders |
| `SummaryService.swift` | Evening summary |
| `GitMonitor.swift` | Worktrees, status and today's commits per project |
| `Notifier.swift` | Notifications with action buttons |
| `Settings.swift` | Preference keys and defaults |
| `Database.swift`, `Util.swift` | SQLite wrapper; JSON helpers, `Shell`, formatters |
| `SelfTest.swift` | `--self-test` harness (per-layer accounting) and the core scenarios |
| `SelfTestSuites.swift` | Unit (incl. property-based), contract (MCP/HTTP) and integration suites, including the end-to-end commit through the bridge |

## Concurrency

- `Core.shared.q` (serial) owns the DB and all mutable core state. HTTP handlers hop onto it.
- Long operations (git, `claude -p`, terminal automation) run on their own queues and call back via `q`.
- Hook replies can be **delayed**: the HTTP connection stays open until a decision or timeout
  (commit approval `approvalTimeout`, permissions `permissionTimeout`).
- `Core.changed()` → `Store.scheduleReload()` (debounced) → `Core.snapshot()` → UI.

## Project resolution for a hook event

1. A session pinned by the human → its project.
2. `cwd` inside a project path, or a worktree sharing the project's git common dir.
3. A session already known → its project.
4. Tool input mentioning a project path or one of its former paths (`aliases`).

## Agent identity and naming

An agent is `(tool, session_id)`. Names are taken from the 100-hero list, unique across open sessions;
legacy Russian names are migrated and still understood in lookups.
