---
audience: all
owner: @Malashkin
updated: 2026-11-10
---

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Rename a project (shown name only) and remove it from the sidebar — keeping its history so re-adding the folder restores tasks, feed and notes, or deleting it; right-click a project in the sidebar.
- Role-based documentation in `docs/` (AGENTS.md entry point, product, architecture with ADRs, backend API, frontend, devops, testing, security, monitoring).
- Local JSON API to create tasks and launch an agent on a task (`POST /api/tasks`, `POST /api/tasks/launch`).
- Automatic board tasks from agents' requests, with titles by a small model; new topic → previous task to review; session end → review.
- Time per client and per task (wall-clock and agent time) in a dashboard widget, in History and in the evening summary.
- "While you were away" digest after a break.
- Actionable macOS notifications: Allow / Deny / answer options / reply to a waiting agent.
- Quick reply field on idle and waiting agent cards.
- Codex hooks (`~/.codex/hooks.json`): live actions, permission requests answered from the app, reservations enforced on patches.
- Pin a session to a project; former project paths remembered when a folder moves.
- Data retention: detailed actions kept 90 days.
- Built-in self-test (`--self-test`, `scripts/test.sh`): 262 checks in unit / contract / integration layers, property-based checks, an end-to-end commit through the real bridge and git hooks.
- `scripts/mutation-check.py`: mutation testing of the riskiest rules.
- Plain-language "what is it doing" line per agent (Claude Haiku via `claude -p`).
- File reservations (`reserve_files` / `release_files`) enforced on edits and by a git pre-commit hook.
- Permission requests, questions and plans answered from the app (dashboard, menu bar).
- Session liveness from Claude Code's session files; stuck/loop detection with a nudge to the agent.
- Subagent lanes; task worktrees with "Start agent", review with line comments, merge, pull request.
- Import of past Claude Code / Codex sessions and git commits when a project is added; last-work date in the sidebar.

### Changed
- Lower CPU use: the pulsing "working" dot is a Core Animation layer animation (a SwiftUI repeat-forever animation re-laid out the whole window every frame, ~30% CPU); relative times refresh every 15 s and not while the window is hidden; git status is polled once a minute while no window is visible.
- The whole app, agent-facing texts and model prompts are in English; Russian input from the human is still understood.
- Agent names are English superhero names, unique across all open sessions (existing names migrated).
- Sessions started outside a project folder are attributed by the files they work on.
- New app logo ("terminals").

### Fixed
- The hook bridge read the port from `~/.agentboard/port` even when the bridge lived elsewhere (`AGENTBOARD_BRIDGE_DIR`), so isolated instances talked to the real app.
- Installers wrote to the real `~/.claude` / `~/.codex` even when `CLAUDE_CONFIG_DIR` / `CODEX_HOME` pointed elsewhere.
- Branch slugs could end with a dash after being cut to 40 characters.
- The legacy name "Икс-23" was not migrated to "X-23".
- `register_agent` from a folder outside every project was attached to the only project instead of being refused.
- Dashboard flicker and lost input (unstable widget ids, global animation on refresh, feed overflowing its widget).
- Agent cards reordering under the cursor on every action.
- System-injected turns (task notifications) recorded as the human's request.
- Liveness check: Claude Code writes process start time in UTC.
- Child `claude` runs inherited the launching Claude Code session's variables.
- A denied edit was recorded as work on the file.

### Removed
- Unused code: `Store.todayEvents`, `String.firstLine`, the `SectionHeader` view, an unused parameter in session delivery.
- Unused logo concept images from `docs/assets`.

### Security
- Web pages can no longer reach the local server: any `Origin` header is refused and POSTs with browser-"simple" content types get 415 (audit H1 — a look-alike domain such as `127.0.0.1.evil.example` passed the old prefix check).
- The evening summary runs `claude -p` without tools, MCP servers or a saved session, with its data marked untrusted (audit M1).
- Messages are typed into a terminal only when the agent is its foreground process; terminal names from hooks are validated (audit M3).
- Isolated runs can no longer edit the real Claude Code / Codex configuration (installers honour `CLAUDE_CONFIG_DIR` / `CODEX_HOME`).
- Requests whose `Host` is not local are refused (DNS rebinding).
- The local server requires a per-install token (`~/.agentboard/token`) on every route except `/health`; the hook bridge and the MCP registrations of Claude Code / Codex send it, and older registrations are refreshed at launch (audit H2, [ADR-007](architecture/decisions/007-per-install-token.md)). **Restart open agent sessions once after updating.**
- MCP callers are identified only by their exact `agent_id` — a name is no longer enough to act as an agent; anonymous callers can't send messages (audit H2/M2).
- `/api/decide`, `/api/tasks` and `/api/tasks/launch` are off unless *Settings → General → Allow scripts to act for me* is on (audit H2).
- Messages from other agents are delivered as fenced, labelled peer information, separate from the human's; agent-written text can't fake the `[AgentBoard]` marker; self-chosen agent names are validated (audit M2).
- `~/.agentboard` is owner-only; task prompt files are 0600 and deleted after launch (audit L1).
- Links in agent/model Markdown are shown with their address and are not clickable (audit L2).
- Server limits: 8 MB per request, 256 connections, 30 s to send a request (audit L3).
- All findings of the 2026-11-09 audit are fixed — see [security/overview.md](security/overview.md).

## [1.0.0] - 2026-11-07

### Added
- AgentBoard: native macOS control panel for multiple Claude Code / Codex agents — hooks, MCP server, live board, feed, commits (log / notify / approve), kanban with clients, history, evening summary.
- Themes, animations, drag-and-drop dashboards, superhero names, Codex log follower, comments into sessions.
- CLI flags to install integrations.
