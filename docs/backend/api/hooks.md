---
audience: backend
owner: @Malashkin
updated: 2026-11-09
---

# Hooks

## Bridge

`~/.agentboard/bin/agentboard-hook <mode>` (bash, rewritten at each launch). Modes:

| Mode | Input | Calls |
|---|---|---|
| `claude` | Claude Code hook JSON on stdin | `POST /hook/claude?tty=…` and prints the response |
| `codex-hook` | Codex hook JSON on stdin | `POST /hook/claude?tool=codex&tty=…` |
| `codex` | Codex `notify` JSON as last argument | `POST /hook/codex` |
| `git-post-commit` | — | `POST /hook/git` `{"cwd","hash"}` (async) |
| `git-pre-commit` | — | `POST /hook/git-precommit` (root + staged files, text); non-empty answer → message on stderr, exit 1 |

If the app is unreachable the bridge exits 0 with no output. `AGENTBOARD_INTERNAL=1` (set for the app's
own child processes) disables it.

## Claude Code / Codex events

| Event | Handling | Response |
|---|---|---|
| SessionStart | register agent, set branch | `additionalContext`: board + team rules |
| UserPromptSubmit | record request (system-injected turns ignored), task autopilot, neighbour digest, inbox | `additionalContext` |
| PreToolUse | record action; Bash `git commit` → commit flow; Edit/Write/apply_patch vs reservations; conflict warnings; loop detection | `permissionDecision` deny/allow/ask or `additionalContext` |
| PermissionRequest | pending request in the app (permission / question / plan) | `decision {behavior, updatedInput?, updatedPermissions?, message?}` — plain allow/deny for Codex |
| PostToolUse | drop matching pending request; inbox | `additionalContext` |
| PostToolUseFailure | record failure; stuck detection + nudge | `additionalContext` |
| SubagentStart / SubagentStop | subagent lanes | — |
| Notification | status *waiting*, notification with reply field | — |
| Stop | final answer; if inbox not empty → `{"decision":"block","reason":…}` | |
| SessionEnd | finish agent, release reservations, task → review | — |

## Git

- **post-commit** records the commit and attributes it to the agent that just ran `git commit` in that checkout.
- **pre-commit** refuses an agent's commit if staged files overlap another active agent's exclusive reservation;
  human commits always pass. Installed after the shebang so existing hooks with `exec` can't skip it.
