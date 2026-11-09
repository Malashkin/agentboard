---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# Security overview

## Assets

- Agents' ability to run code as the user (the most valuable target).
- Prompts, answers, file names, task and client data in the database.
- The user's Claude Code / Codex configuration.

## Threats considered

| Actor | Path |
|---|---|
| Web page in the user's browser | Requests to `127.0.0.1:7777` (CSRF, DNS rebinding) |
| Other local process / other user account | The unauthenticated local server |
| Untrusted content read by an agent | Prompt injection spreading through messages, notes, summaries |
| Mistakes | Text typed into the wrong terminal; agents overwriting each other |

## Controls in place

- Listener bound to loopback; `Host` must be `127.0.0.1`/`localhost` (DNS rebinding); cross-site `Origin` refused.
- Parameterized SQL; processes spawned with argv; terminal launch command fully quoted.
- Model calls without tools for narrator, titles and digest; Claude session variables stripped.
- Reservations enforced on edits and commits; human commits never blocked; hooks fail open.
- "Allow for this session" never persists rules; Codex answers are plain allow/deny.
- Config edits backed up; only AgentBoard's own entries touched. No secrets in the repository.

## Open issues (2026-11-09 audit)

| ID | Severity | Summary | Planned fix |
|---|---|---|---|
| H1 | High | `Origin` checked by prefix — look-alike domains pass; text/plain POSTs need no preflight | Exact origin match / reject any Origin; JSON-only POSTs |
| H2 | High | No authentication on hooks/MCP/API; MCP accepts an agent name as identity | Per-install token (0600) for bridge, MCP and API; ids-only identity |
| M1 | Medium | Evening summary runs `claude -p` with tools while `mcp__agentboard` is auto-allowed | Run without tools / safe mode |
| M2 | Medium | Peer-agent messages injected with platform authority; free agent names | Frame as untrusted; validate names |
| M3 | Medium | Terminal typing doesn't verify the agent is in the foreground | Foreground-process check; strict tty format |
| L1–L3 | Low | `~/.agentboard` world-readable; clickable links in model/agent Markdown; no request limits | 0700/0600; plain links; limits |

Status and order: [product/roadmap.md](../product/roadmap.md).

## Data leaving the Mac

Only through `claude -p` calls (narrator, task titles, away digest, evening summary), using the user's
Claude Code login. All can be disabled in Settings.
