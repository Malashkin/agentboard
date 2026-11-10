---
audience: all
owner: @Malashkin
updated: 2026-11-10
---

# ADR-007: Per-install token for the local server, identity by agent id

**Status:** Accepted
**Date:** 2026-11-10
**Authors:** @Malashkin

## Context

The server on `127.0.0.1:7777` (hooks, MCP, `/api/*`) had no credentials. Loopback is reachable by every process
and every user account on the Mac, including sandboxed apps. Anyone could read every prompt, act as an agent by
naming it (`"agent_id": "Batman"`), message all agents, approve pending permission requests and launch agents
with arbitrary prompts (security audit H2).

## Decision

- A 32-byte random token in `~/.agentboard/token` (0600, folder 0700), created at first launch.
- Every route except `GET /health` requires it (`X-AgentBoard-Token` or `Authorization: Bearer`), compared in
  constant time; 401 otherwise.
- The hook bridge reads it with `curl -H @~/.agentboard/auth-header`, so it never appears in a process list.
- Claude Code and Codex are registered for MCP with `Authorization: Bearer <token>`; registrations without it
  (older versions, another port) are refreshed at launch.
- MCP callers are identified only by exact `agent_id` (or the preceding hook). Names remain valid as targets.
- Routes that act for the human (`/api/decide`, `/api/tasks`, `/api/tasks/launch`) are off unless enabled in Settings.

## Consequences

- ✅ Other users, sandboxed apps and web pages can't reach the board or impersonate agents.
- ✅ No change for the user beyond restarting agent sessions once (they load the new MCP header at start).
- ❌ Processes running as the same user can read the token — out of scope (they could edit Claude's settings anyway).
- ❌ Open sessions that loaded MCP without the header get 401 from MCP until restarted; hooks keep working.

## Alternatives considered

- **Unix domain socket with file permissions** — MCP clients of Claude Code / Codex speak HTTP over TCP only.
- **Token embedded in the bridge script** — visible in `ps` when passed to curl as an argument.
- **Keychain** — the bridge (bash) and MCP clients can't read it without prompts.
