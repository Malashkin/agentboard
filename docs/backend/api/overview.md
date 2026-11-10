---
audience: backend
owner: @Malashkin
updated: 2026-11-10
---

# Local API overview

> Base URL: `http://127.0.0.1:<port>` (default port 7777; written to `~/.agentboard/port`)

| Method | Path | Used by | Doc |
|---|---|---|---|
| GET | `/health` | anyone (no token) | `{"ok":true,"app":"AgentBoard","version":…}` |
| POST | `/hook/claude[?tty=ttysNNN][&tool=codex]` | Claude Code and Codex hooks via the bridge | [hooks.md](hooks.md) |
| POST | `/hook/codex` | Codex `notify` | [hooks.md](hooks.md) |
| POST | `/hook/git` | git post-commit | [hooks.md](hooks.md) |
| POST | `/hook/git-precommit` | git pre-commit | [hooks.md](hooks.md) |
| POST | `/mcp` | MCP clients (JSON-RPC 2.0, JSON responses; GET → 405, DELETE → 200) | [mcp.md](mcp.md) |
| GET | `/api/board` | scripts | [http-api.md](http-api.md) |
| GET | `/api/pending` | scripts | [http-api.md](http-api.md) |
| POST | `/api/decide` | scripts, opt-in | [http-api.md](http-api.md) |
| POST | `/api/tasks` | scripts, opt-in | [http-api.md](http-api.md) |
| POST | `/api/tasks/launch` | scripts, opt-in | [http-api.md](http-api.md) |

## Authentication

Every route except `GET /health` needs the install's token (audit H2):

```http
X-AgentBoard-Token: <contents of ~/.agentboard/token>
# or
Authorization: Bearer <token>
```

- The hook bridge sends it from `~/.agentboard/auth-header` (`curl -H @file`); MCP clients are registered with
  `Authorization: Bearer …` (Integrations → Connect; old registrations are refreshed at launch).
- Missing or wrong token → 401 (constant-time comparison).
- "Opt-in" routes act for the human and answer 403 unless *Settings → General → Allow scripts to act for me* is on.
- `Host` must be `127.0.0.1`, `localhost` or `[::1]` → otherwise 403 (DNS rebinding).
- Any `Origin` header → 403. Hooks, git hooks and MCP clients never send one; browsers always do.
- `POST` must not use a browser-"simple" content type (`text/plain`, `application/x-www-form-urlencoded`,
  `multipart/form-data`, or none) → otherwise 415. Use `application/json` (or `application/octet-stream` for raw bodies).
- Limits: 8 MB per request (413), 256 open connections, 30 s to send a complete request.

See [security/overview.md](../../security/overview.md).

## Errors

| Code | Meaning |
|---|---|
| 400 | Missing or invalid fields (JSON body) |
| 401 | Missing or wrong token |
| 403 | Forbidden origin or host; opt-in route switched off |
| 413 | Request larger than 8 MB |
| 415 | POST with a browser-simple or missing content type |
| 404 | Unknown path, task or pending request |
| 500 | Operation failed (message in `error`) |
