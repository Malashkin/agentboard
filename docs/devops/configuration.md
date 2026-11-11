---
audience: devops
owner: @Malashkin
updated: 2026-11-11
---

# Configuration

## Settings (UserDefaults, Settings window)

| Key | Default | Description |
|---|---|---|
| `port` | 7777 | Local server port (MCP registrations are refreshed at the next launch) |
| `scriptingAPI` | false | Allow `/api/decide`, `/api/tasks`, `/api/tasks/launch` (Settings → General → Allow scripts to act for me) |
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
| `globalHotkeys` | true | ⌥⌘J (next agent that needs you) / ⌥⌘K (*Needs you* panel) from any app |
| `ignoredProjectSuggestions` | [] | Folders not to suggest again |

## Environment variables

| Variable | Effect |
|---|---|
| `AGENTBOARD_DATA_DIR` | Database folder; also enables test mode (no model calls, no auto summary) |
| `AGENTBOARD_BRIDGE_DIR` | Folder for the bridge script and its `port` file (default `~/.agentboard`); the bridge always uses the port file next to itself |
| `AGENTBOARD_WORKTREE_ROOT` | Overrides `worktreeRoot` |
| `CLAUDE_CONFIG_DIR` | Claude Code folder (default `~/.claude`): sessions, transcripts **and** the `settings.json` the installers edit |
| `GEMINI_CLI_HOME` | Gemini CLI home (its `.gemini/settings.json` is what the installer edits; default `~`) |
| `CODEX_HOME` | Codex folder (default `~/.codex`): logs **and** the `config.toml` / `hooks.json` the installers edit |
| `AGENTBOARD_SNAPSHOT`, `AGENTBOARD_SNAPSHOT_DELAY` | Debug: save a PNG of the main window after N seconds |
| `AGENTBOARD_INTERNAL` | Set for the app's child processes; makes the bridge a no-op |

## Command-line flags

`-port N` · `--install-claude` · `--install-codex` · `--install-gemini` · `--uninstall-claude` · `--uninstall-gemini` · `--discover` · `--self-test`

## Files

| Path | Content |
|---|---|
| `~/Library/Application Support/AgentBoard/agentboard.sqlite` | All data |
| `~/.agentboard/` | Owner-only folder (0700) |
| `~/.agentboard/bin/agentboard-hook`, `~/.agentboard/port` | Bridge |
| `~/.agentboard/token`, `~/.agentboard/auth-header` | The install's API token and the curl header line (0600) — see [ADR-007](../architecture/decisions/007-per-install-token.md) |
| `~/.agentboard/telegram.json` | Telegram bot token, paired chat, "only when away" (0600; only after pairing) |
| `~/.agentboard/prompts/task-N.txt` | Prompt of a task being launched (0600, deleted once the agent has read it) |
| `~/.agentboard/worktrees/` | Task worktrees |
| `~/Documents/AgentBoard/YYYY-MM-DD.md` | Exported summaries |
