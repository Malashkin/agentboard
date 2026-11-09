---
audience: devops
owner: @Malashkin
updated: 2026-11-09
---

# Monitoring and diagnostics

AgentBoard is a desktop app; there are no remote metrics. Health is checked locally.

## Health checks

| Check | How |
|---|---|
| Server up | `curl -s 127.0.0.1:7777/health` → `{"ok":true,…}`; green dot at the bottom of the sidebar |
| Claude hooks installed | Integrations screen; `~/.claude/settings.json` has `agentboard-hook` entries |
| MCP connected | `claude mcp list` → `agentboard … ✔ Connected` |
| Agents seen | `sqlite3 ~/Library/Application\ Support/AgentBoard/agentboard.sqlite "select name,status from agents where status!='ended'"` |
| Pending decisions | `curl -s 127.0.0.1:7777/api/pending` |

## Where things are recorded

- **Everything agents do** — table `events` (see [backend/data-model.md](../backend/data-model.md)).
- **Errors shown to the user** — banners at the top of the window (server/DB errors) and macOS notifications.
- **Notifications fallback** — when not running as a bundle, notifications go to the system log (`NSLog`).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| A session isn't on the board | Started before hooks were installed (restart it); folder not trusted in Claude Code; project folder moved (edit path / aliases); session started outside the project (pin it) |
| Agent shown as inactive while its terminal is open | Old Claude Code without session files; check `~/.claude/sessions` |
| Nothing happens on "Start agent" | Automation permission for Terminal/iTerm (System Settings → Privacy → Automation) |
| No narratives / titles | `claude` not in PATH, logged out, or the feature is off; repeated failures back off for a few minutes |
