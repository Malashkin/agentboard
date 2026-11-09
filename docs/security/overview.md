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

- Listener bound to loopback; `Host` must be `127.0.0.1`/`localhost` (DNS rebinding).
- Any request carrying an `Origin` header is refused (403) — only browsers send it; POSTs with a browser-"simple"
  content type (`text/plain`, forms, none) are refused (415), so a web page can't reach the server without a preflight it never gets.
- Parameterized SQL; processes spawned with argv; terminal launch command fully quoted.
- Every model call (narrator, titles, digest, evening summary) runs `claude -p --tools "" --safe-mode --no-session-persistence`
  (`Shell.modelArgs`); the summary's data is delimited and declared untrusted. Claude session variables stripped.
- Text is typed into a terminal only when the agent is that terminal's foreground process; tty names must be `ttysNNN`.
- Reservations enforced on edits and commits; human commits never blocked; hooks fail open.
- "Allow for this session" never persists rules; Codex answers are plain allow/deny.
- Config edits backed up; only AgentBoard's own entries touched. No secrets in the repository.

## Open issues (2026-11-09 audit)

| ID | Severity | Summary | Planned fix |
|---|---|---|---|
| H1 | High | `Origin` checked by prefix — look-alike domains passed; text/plain POSTs needed no preflight | ✅ Fixed 2026-11-09: any Origin → 403, simple content types → 415 |
| H2 | High | No authentication on hooks/MCP/API; MCP accepts an agent name as identity | Open — per-install token (0600) for bridge, MCP and API; ids-only identity |
| M1 | Medium | Evening summary ran `claude -p` with tools while `mcp__agentboard` is auto-allowed | ✅ Fixed 2026-11-09: no tools / safe mode, data delimited as untrusted |
| M2 | Medium | Peer-agent messages injected with platform authority; free agent names | Open — frame as untrusted; validate names |
| M3 | Medium | Terminal typing didn't verify the agent is in the foreground | ✅ Fixed 2026-11-09: foreground-process check; strict tty format |
| L1–L3 | Low | `~/.agentboard` world-readable; clickable links in model/agent Markdown; no request limits | 0700/0600; plain links; limits |

Status and order: [product/roadmap.md](../product/roadmap.md).

## Data leaving the Mac

Only through `claude -p` calls (narrator, task titles, away digest, evening summary), using the user's
Claude Code login. All can be disabled in Settings.
