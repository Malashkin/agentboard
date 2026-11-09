---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
- Built-in end-to-end self-test (`--self-test`, `scripts/test.sh`, 38 checks).
- Plain-language "what is it doing" line per agent (Claude Haiku via `claude -p`).
- File reservations (`reserve_files` / `release_files`) enforced on edits and by a git pre-commit hook.
- Permission requests, questions and plans answered from the app (dashboard, menu bar).
- Session liveness from Claude Code's session files; stuck/loop detection with a nudge to the agent.
- Subagent lanes; task worktrees with "Start agent", review with line comments, merge, pull request.
- Import of past Claude Code / Codex sessions and git commits when a project is added; last-work date in the sidebar.

### Changed
- The whole app, agent-facing texts and model prompts are in English; Russian input from the human is still understood.
- Agent names are English superhero names, unique across all open sessions (existing names migrated).
- Sessions started outside a project folder are attributed by the files they work on.
- New app logo ("terminals").

### Fixed
- Dashboard flicker and lost input (unstable widget ids, global animation on refresh, feed overflowing its widget).
- Agent cards reordering under the cursor on every action.
- System-injected turns (task notifications) recorded as the human's request.
- Liveness check: Claude Code writes process start time in UTC.
- Child `claude` runs inherited the launching Claude Code session's variables.
- A denied edit was recorded as work on the file.

### Security
- Requests whose `Host` is not local are refused (DNS rebinding).
- Known open issues from the 2026-11-09 audit are tracked in [security/overview.md](security/overview.md).

## [1.0.0] - 2026-11-07

### Added
- AgentBoard: native macOS control panel for multiple Claude Code / Codex agents — hooks, MCP server, live board, feed, commits (log / notify / approve), kanban with clients, history, evening summary.
- Themes, animations, drag-and-drop dashboards, superhero names, Codex log follower, comments into sessions.
- CLI flags to install integrations.
