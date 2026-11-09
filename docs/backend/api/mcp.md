---
audience: backend
owner: @Malashkin
updated: 2026-11-09
---

# MCP tools

> Endpoint: `POST http://127.0.0.1:7777/mcp` (Streamable HTTP, JSON responses, no SSE). Server name: `agentboard`.

Claude Code sessions are identified automatically (the call is matched to the `PreToolUse` hook that
preceded it). Other clients call `register_agent(cwd)` first and pass `agent_id`. Every tool also
accepts `agent_id` and `project_path`.

| Tool | Parameters | Effect |
|---|---|---|
| `board` | — | Active agents, open tasks, reservations, recent notes/commits (read-only) |
| `agent_activity` | `agent?`, `limit?` | What another agent is doing: request, narrative, files, timeline, last answer |
| `list_tasks` | `status?`, `client?`, `include_done?` | Tasks of the project |
| `create_task` | `title`, `details?`, `client?`, `status?`, `claim?` | New task (optionally take it) |
| `claim_task` | `task_id`, `force?` | Take a task (refused if another active agent has it) |
| `update_task` | `task_id`, `status?`, `note?`, `client?`, `release?` | Status, report, release |
| `set_focus` | `focus`, `files?` | Declare current work; warns about overlaps |
| `send_message` | `to` (name, id, `all`), `text` | Message delivered into the target's context |
| `post_note` | `text`, `client?` | Note in the feed |
| `who_touches` | `path` | Recent editors and reservation holder |
| `reserve_files` | `paths[]`, `minutes?`, `exclusive?`, `reason?` | Lease files/folders/globs (renew by calling again) |
| `release_files` | `paths[]?` | Release own leases (all if omitted) |
| `register_agent` | `cwd`, `tool?`, `name?` | For clients without hooks; returns `agent_id` |

Results are plain text in `content[0].text`; `isError` marks refusals. Pending inbox messages are
appended to tool results.
