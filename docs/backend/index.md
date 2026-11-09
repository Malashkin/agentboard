---
audience: backend
owner: @Malashkin
updated: 2026-11-09
---

# Backend (core engine)

The non-UI part of the app: local HTTP server, hook handling, MCP tools, coordination, background
services and the SQLite data model.

## In this section

| File | What it answers |
|---|---|
| [overview.md](overview.md) | Which file does what, and how is concurrency handled? |
| [data-model.md](data-model.md) | What is stored and how is it related? |
| [services.md](services.md) | Which background services run, how often, and what do they do? |
| [api/](api/index.md) | What endpoints, hooks and MCP tools exist on 127.0.0.1:7777? |
| [api/hooks.md](api/hooks.md) | How are Claude Code / Codex / git hooks handled? |
| [api/mcp.md](api/mcp.md) | Which MCP tools can agents call? |
| [api/http-api.md](api/http-api.md) | What does the local JSON API offer? |

See also: [AGENTS.md](../AGENTS.md) · [Architecture](../architecture/index.md)
