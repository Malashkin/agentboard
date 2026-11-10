---
audience: backend
owner: @Malashkin
updated: 2026-11-10
---

# Background services

| Service | Interval / trigger | What it does |
|---|---|---|
| `CodexWatcher` | every 2 s | Tails `~/.codex/sessions/**/rollout-*.jsonl` (today/yesterday) for sessions that don't report via hooks |
| `SessionLiveness` | every 5 s | Reads `~/.claude/sessions/*.json`, checks pid + start time; refreshes open sessions, ends sessions whose process disappeared, fixes missed `Stop` |
| `GitMonitor` | every 15 s (every 60 s while the window is hidden) | Worktrees, status and today's commits per project |
| UI ticker | every 15 s, only while the window is visible | Refreshes relative times ("5 min ago") |
| `Narrator` | tick every 20 s | For agents with new events: plain-language line, at most every `narratorMinutes` (status changes immediately) |
| `TaskAutopilot` | on each human prompt / session end | Creates/rotates auto tasks; session end → review |
| `AwayWatcher` | app/screen inactive ≥ `awayMinutes` | Digest of what happened meanwhile |
| Summary timer | every 60 s | Writes the evening summary within an hour after the set time; yesterday's on next launch |
| History import | project added; each launch | Imports past sessions/commits once; appends new tail of open sessions |
| Retention | each launch | Deletes old detailed data |
| Git hooks refresh | each launch | Re-installs pre/post-commit hooks for all projects (idempotent) |

All model calls use `claude -p --model <narratorModel> --tools "" --safe-mode --no-session-persistence`
except the evening summary (see [security/overview.md](../security/overview.md)). Nothing calls a model in test mode.
