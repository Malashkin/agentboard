<p align="center"><img src="docs/logo.png" width="160" alt="AgentBoard"></p>

# AgentBoard

Headquarters for your superhero agents: a hero mask with glowing "AI eyes" above a three-column board: working, waiting for you, idle.

A native macOS app (SwiftUI): a control panel for multiple **Claude Code** and **Codex** agents working on the same projects.

- **See everything in real time.** Each terminal is a separate agent with a superhero name (100 built in): status (working / waiting for you / idle), request, task, focus, files, branch, last action. The feed records **all** activity: requests, commands, edits, file reads, searches, subagents, MCP calls, replies, commits.
- **Agents know about each other.** At session start and on new requests, Claude gets a summary of its neighbors. Through the `agentboard` MCP server an agent can see what a neighbor is doing (`agent_activity`), claim a task, declare its focus and message another agent. If an agent starts editing a file another agent recently changed, it gets a warning.
- **Message the session.** From the dashboard you can send a message to a specific agent, and it will continue working with it in mind:
  - agent is working → the message lands in its context on the next step;
  - agent is waiting for input → the text is typed into its Terminal.app / iTerm2 / tmux tab;
  - session is closed → "Continue in background" (`claude -p --resume` / `codex exec resume`).
- **Commits under control.** Modes: log to the feed, notify, or ask for approval (the agent waits until you click "Allow" in the window or the menu bar). A git post-commit hook captures commits from any agent across all worktrees.
- **Tasks and clients.** A kanban board (Backlog / In progress / In review / Done) with a client per task. Assign a task to an agent from the dashboard and the agent gets a message.
- **History** for any past day: agents, their timelines, commits, closed tasks, clients.
- **Evening summary.** At a scheduled time, `claude -p` writes a report: the day's highlights, what was done per project in code and per client, what's unfinished, and what needs attention. The report is saved in the app and to `~/Documents/AgentBoard/YYYY-MM-DD.md`.

- **Make it yours.** 8 color schemes (System, Midnight, Graphite, Ocean, Forest, Sunset, Paper, Mint), a custom accent color, light/dark mode, density, card style (filled / outlined / glass), animations and pulsing status indicators.
- **Drag-and-drop layout.** The Overview and each project's dashboard are built from widgets: stats, awaiting decision, agents, feed, tasks in progress, commits, clients, hot files, latest summary. In Customize mode you can drag them around, make them half or full width, hide them and add new ones. Projects in the sidebar can also be reordered by dragging.

Real data only: the app ships with no demo content. Everything is stored locally (SQLite in `~/Library/Application Support/AgentBoard`), and the server listens only on `127.0.0.1`.

## Installation

Requires macOS 14+ and the Command Line Tools (`xcode-select --install`). Xcode is not needed.

```sh
./scripts/build-app.sh            # build dist/AgentBoard.app
./scripts/build-app.sh --install  # build and copy to /Applications
```

Then, in the app:
1. **Integrations** → "Connect": Claude Code hooks, the MCP server, Codex (if you use it).
2. **Add project**: pick a git repository folder. The git post-commit hook is installed right away.
3. For Codex, click "Add rules to AGENTS.md" in the project settings.
4. Restart any Claude Code sessions that are already open.

If the app isn't running, the hooks silently do nothing and don't get in the agents' way.

## How it works

```
Claude Code ──hooks──▶ ~/.agentboard/bin/agentboard-hook ──HTTP──▶ AgentBoard.app (127.0.0.1:7777)
            ◀─ additionalContext / commit decisions / messages ─┘            │
Claude/Codex ──MCP (http://127.0.0.1:7777/mcp)──────────────────────────────▶│  SQLite
Codex ── logs ~/.codex/sessions/**/rollout-*.jsonl (read in real time) ─────▶│
git ── post-commit ──▶ agentboard-hook ─────────────────────────────────────▶│
```

| Claude Code hook | What it does |
|---|---|
| SessionStart | registers the agent, gives it the rules and the board state |
| UserPromptSubmit | records the request; reports what neighbors are doing; delivers messages |
| PreToolUse (all tools) | logs the action to the feed; intercepts `git commit`; warns about file conflicts |
| PostToolUse | delivers comments and messages to the agent while it works |
| Notification | "agent is waiting for you" + a macOS notification |
| Stop | records the final reply; if a message arrived, keeps the agent from stopping until it reads it |
| SessionEnd | marks the session as finished |

MCP tools: `board`, `agent_activity`, `send_message`, `list_tasks`, `create_task`, `claim_task`, `update_task`, `set_focus`, `post_note`, `who_touches`, `register_agent`.

## Development

```sh
swift build && .build/debug/AgentBoard -port 7788      # debug on a different port
AGENTBOARD_DATA_DIR=/tmp/ab AGENTBOARD_BRIDGE_DIR=/tmp/ab/.agentboard CODEX_HOME=/tmp/ab/codex \
  .build/debug/AgentBoard -port 7788                   # fully isolated run
```
