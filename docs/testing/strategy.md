---
audience: testing
owner: @Malashkin
updated: 2026-11-09
---

# Test strategy

The project builds without Xcode, so there is no XCTest. Verification has three layers:

1. **Built-in self-test** (`--self-test`) — end-to-end checks of the core on throwaway data: a temporary
   database, git repository and Claude/Codex folders. Hooks and MCP are exercised through the same entry
   points as in production (`handleClaudeHook`, `route`). No model is ever called.
2. **Isolated instance** on another port with its own data dir, driven with `curl` against `/hook/*`,
   `/mcp`, `/api/*` — for flows that need time (liveness) or the UI.
3. **Window snapshots** (`AGENTBOARD_SNAPSHOT`) to check layout and rendering without screen-recording permission.

## Covered by the self-test (38 checks)

Names and patterns · sessions and unique names · reservations (grant, refuse, deny edit, no bookkeeping
for denied edits, pre-commit refusal, holder's commit passes, Codex patch denied, Codex hook sessions) ·
questions/permissions (answer reaches agent, Codex plain allow, answered in terminal → dropped) ·
stuck detection and nudge · subagents · auto tasks and short replies · time report · session end → review ·
worktree, diff, merge, removal · history import (once) · pinning · retention · HTTP host/origin safety.

## Not covered (manual)

SwiftUI views, notifications and their actions, terminal typing (AppleScript/tmux), launching agents in
Terminal, Codex log parsing against real logs, installers' edits of real config files, model-generated
text (narrator, titles, digest, summary).

## Rule

Every behavior change in the core gets a self-test check in the same commit.
