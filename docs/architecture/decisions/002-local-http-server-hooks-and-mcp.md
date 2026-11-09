---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# ADR-002: Local HTTP server for hooks and MCP

**Status:** Accepted
**Date:** 2026-11-09
**Authors:** @Malashkin

## Context

Claude Code and Codex expose hooks (shell commands with JSON on stdin/stdout) and MCP. AgentBoard must receive every event, sometimes hold a hook open until a human decides, and answer tool calls from agents.

## Decision

Run one HTTP/1.1 server on `127.0.0.1:<port>` (default 7777). Hooks call a tiny bash bridge (`~/.agentboard/bin/agentboard-hook`) that POSTs to it with `curl` and prints the reply. MCP uses the Streamable HTTP transport (JSON responses only) on `/mcp`. The bridge exits silently when the app is down.

## Consequences

### Positive
- One code path for Claude Code and Codex hooks (same JSON shape).
- Hooks can be held for decisions (commit approval, permission requests).
- Agents never break when the app isn't running.

### Negative
- A local network service: needs authentication and browser-origin defenses (open items H1/H2 in the security audit).

## Alternatives Considered

### Unix domain socket
- Pros: filesystem permissions as auth.
- Why rejected: MCP clients and `curl` in hooks speak HTTP over TCP most simply. Revisit together with the token work.
