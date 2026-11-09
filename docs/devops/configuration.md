---
audience: devops
owner: @Malashkin
updated: 2026-11-09
---

# Configuration

## Settings (UserDefaults, Settings window)

| Key | Default | Description |
|---|---|---|
| `port` | 7777 | Local server port (re-register MCP after changing) |
| `commitMode` | `notify` | `off` · `notify` · `approve` |
| `approvalTimeout` | 300 s | Wait for a commit decision, then fall back to the terminal |
| `permissionTimeout` | 900 s | How long a permission request waits in the app |
| `permissionsInApp` | true | Show permissions/questions/plans in the app |
| `injectContext` | true | Tell agents what neighbours do |
| `conflictWarnings` | true | Warn about files edited by others |
| `blockReservedEdits` | true | Deny edits of other agents' reservations |
| `reservationMinutes` | 30 | Default lease length |
| `stuckDetection` / `stuckNudge` | true / true | Detect loops / tell the agent |
| `narrator` / `narratorMinutes` / `narratorModel` | true / 2 / `haiku` | Plain-language status lines |
| `autoTasks` | true | Tasks from agents' requests |
| `awayDigest` / `awayMinutes` | true / 20 | *While you were away* |
| `autoSummary` / `summaryHour` / `summaryMinute` | true / 19 / 0 | Evening summary time |
| `summaryModel` | "" | Model for the summary (empty = Claude Code default) |
| `exportDir` | `~/Documents/AgentBoard` | Where summaries are saved as `.md` |
| `staleMinutes` | 30 | Inactive after this much silence |
| `terminalApp` | `Terminal` | `Terminal` or `iTerm` for launched tasks |
| `worktreeRoot` | `~/.agentboard/worktrees` | Where task worktrees are created |
| `notifyCommits` / `notifyWaiting` / `notifyConflicts` | true | Notifications |

## Environment variables

| Variable | Effect |
|---|---|
| `AGENTBOARD_DATA_DIR` | Database folder; also enables test mode (no model calls, no auto summary) |
| `AGENTBOARD_BRIDGE_DIR` | Folder for the bridge script and port file (default `~/.agentboard`) |
| `AGENTBOARD_WORKTREE_ROOT` | Overrides `worktreeRoot` |
| `CLAUDE_CONFIG_DIR` | Claude Code folder for sessions/transcripts (default `~/.claude`) |
| `CODEX_HOME` | Codex folder (default `~/.codex`) |
| `AGENTBOARD_SNAPSHOT`, `AGENTBOARD_SNAPSHOT_DELAY` | Debug: save a PNG of the main window after N seconds |
| `AGENTBOARD_INTERNAL` | Set for the app's child processes; makes the bridge a no-op |

## Command-line flags

`-port N` · `--install-claude` · `--install-codex` · `--uninstall-claude` · `--self-test`

## Files

| Path | Content |
|---|---|
| `~/Library/Application Support/AgentBoard/agentboard.sqlite` | All data |
| `~/.agentboard/bin/agentboard-hook`, `~/.agentboard/port` | Bridge |
| `~/.agentboard/prompts/task-N.txt` | Prompts of launched tasks |
| `~/.agentboard/worktrees/` | Task worktrees |
| `~/Documents/AgentBoard/YYYY-MM-DD.md` | Exported summaries |
