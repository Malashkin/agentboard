---
audience: backend
owner: @Malashkin
updated: 2026-11-11
---

# Hooks

## Bridge

`~/.agentboard/bin/agentboard-hook <mode>` (bash, rewritten at each launch). Modes:

| Mode | Input | Calls |
|---|---|---|
| `claude` | Claude Code hook JSON on stdin | `POST /hook/claude?tty=…` and prints the response |
| `codex-hook` | Codex hook JSON on stdin | `POST /hook/claude?tool=codex&tty=…` |
| `codex` | Codex `notify` JSON as last argument | `POST /hook/codex` |
| `gemini` | Gemini CLI hook JSON on stdin | `POST /hook/gemini?tty=…`; the app translates it to Claude Code's shape (`GeminiHooks.toClaude`), runs the same handler with `agentTool = "gemini"`, and translates the answer back (`GeminiHooks.fromClaude`) |
| `git-post-commit` | — | `POST /hook/git` `{"cwd","hash"}` (async) |
| `git-pre-commit` | — | `POST /hook/git-precommit` (`application/octet-stream`: root + staged files, one per line); non-empty answer → message on stderr, exit 1 |

The bridge reads the port from the `port` file next to its own `bin/` folder (`~/.agentboard/port`, or
`$AGENTBOARD_BRIDGE_DIR/port` for an isolated instance), so a test instance's hooks never reach the real app. Every call sends the install's token with
`curl -H @"$BASE/auth-header"` (0600 file written by the app), so the token is never on a command line.
If the app is unreachable the bridge exits 0 with no output. `AGENTBOARD_INTERNAL=1` (set for the app's
own child processes) disables it.

## Claude Code / Codex events

| Event | Handling | Response |
|---|---|---|
| SessionStart | register agent, set branch | `additionalContext`: board + project memory + team rules |
| UserPromptSubmit | record request (system-injected turns ignored), task autopilot, neighbour digest, overlap heads-up (paths in the prompt vs others' recent edits and reservations), inbox | `additionalContext` |
| PreToolUse | record action; Bash `git commit` → commit flow; Edit/Write/apply_patch vs reservations; conflict warnings; loop detection | `permissionDecision` deny/allow/ask or `additionalContext` |
| PermissionRequest | pending request in the app (permission / question / plan) | `decision {behavior, updatedInput?, updatedPermissions?, message?}` — plain allow/deny for Codex |
| PostToolUse | drop matching pending request; inbox | `additionalContext` |
| PostToolUseFailure | record failure; stuck detection + nudge | `additionalContext` |
| SubagentStart / SubagentStop | subagent lanes | — |
| Notification | status *waiting* (the idle nudge "…waiting for your input" with nothing pending → *idle*, no notification), notification with reply field, Telegram | — |
| Stop | final answer; if inbox not empty → `{"decision":"block","reason":…}` | |
| SessionEnd | finish agent, release reservations, task → review | — |

## Gemini CLI events

| Gemini CLI | Handled as | Answer back |
|---|---|---|
| SessionStart | SessionStart | `hookSpecificOutput.additionalContext` |
| BeforeAgent | UserPromptSubmit | `additionalContext` |
| BeforeTool | PreToolUse (tools mapped: `run_shell_command`→Bash, `replace`→Edit, `write_file`→Write, `read_file`→Read, …) | refusal → `{"decision":"deny","reason":…}` |
| AfterTool | PostToolUse, or PostToolUseFailure when `tool_response.error` is set | `additionalContext` |
| AfterAgent | Stop (`prompt_response` → last answer) | inbox waiting → `{"decision":"deny","reason":…}` (Gemini continues) |
| Notification / SessionEnd | same | — |

## Git

- **post-commit** records the commit and attributes it to the agent that just ran `git commit` in that checkout.
- **pre-commit** refuses an agent's commit if staged files overlap another active agent's exclusive reservation;
  human commits always pass. Installed after the shebang so existing hooks with `exec` can't skip it.
