---
audience: product
owner: @Malashkin
updated: 2026-11-11
---

# Roadmap

| Item | Status | Priority |
|---|---|---|
| Security hardening: refuse Origin, non-simple POSTs only (audit H1) | Done | P0 |
| Per-install token for hooks / MCP / API; ids-only agent identity (audit H2) | Done | P0 |
| Evening summary run without tools (audit M1) | Done | P1 |
| Foreground check before typing into a terminal (audit M3) | Done | P1 |
| Peer messages framed as untrusted; validated agent names (audit M2) | Done | P1 |
| Private `~/.agentboard`, non-clickable agent links, server limits (audit L1–L3) | Done | P2 |
| Jump to an agent's terminal; ⌥⌘J / ⌥⌘K from any app | Done | P1 |
| Open sessions on the board before any hook | Done | P1 |
| Gemini CLI support | Done (not yet run against a live Gemini CLI) | P1 |
| Overlap warning when a request arrives | Done | P1 |
| Project memory (`remember`) | Done | P1 |
| Briefings between sessions (`handoff`) | Done | P2 |
| Session replay with diffs | Done | P2 |
| Phone via Telegram | Done (not yet run against a live bot) | P2 |
| More CLIs: Cursor Agent, OpenCode, Copilot CLI | Idea | P2 |
| Auto-trust task worktrees of already trusted repositories (opt-in) | Idea | P2 |
| Proper singular/plural in English counters | Idea | P3 |
| Signed and notarized builds, auto-update | Idea | P3 |
| UI automation tests (beyond the core self-test) | Idea | P3 |

Security items refer to the confidential local audit report; see [security/overview.md](../security/overview.md).
