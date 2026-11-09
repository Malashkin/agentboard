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

## Layers (165 checks)

| Layer | Checks | What it pins down |
|---|---|---|
| Unit | 61 | git command recognition, reservation patterns (+ symmetry property), project mentions, Codex patch/command parsing, diff parser (+ properties: counts, line numbering), branch slugs (+ property: safe charset), shell quoting (+ property: round trip through `/bin/sh`), system-turn detection, work requests, legacy → English names, durations, timestamps |
| Contract | 22 | MCP: initialize, exact tool list, schemas, error codes (−32700, −32601), notifications, batches; HTTP: status codes and bodies of every route, Host/Origin refusals |
| Integration | 82 | Sessions and names, reservations (edit deny, pre-commit), questions/permissions (Claude + Codex, parallel tools), stuck detection, subagents, auto tasks and time, worktree/diff/merge, history import, pinning, retention, Codex log, installers inside `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, git hook placement, **end to end: real HTTP server + real bridge + real `git commit`**, session liveness, MCP tool rules, message delivery, inputs of model-written texts |

Property-based checks use a seeded generator (`SeededRNG`), so every run sees the same cases.

## Quality gate: mutation testing

`scripts/mutation-check.py` applies hand-picked mutants to the riskiest rules (one at a time), rebuilds and
runs the self-test; each mutant must be killed. Results are in `TEST_RESULTS.md`. No Swift mutation tool
works without Xcode, hence the script.

## Coverage (diagnostic)

```sh
swift build -c debug --build-path /tmp/abcov -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping
LLVM_PROFILE_FILE=/tmp/abcov/ab.profraw /tmp/abcov/debug/AgentBoard --self-test
xcrun llvm-profdata merge -sparse /tmp/abcov/ab.profraw -o /tmp/abcov/ab.profdata
xcrun llvm-cov report /tmp/abcov/debug/AgentBoard -instr-profile=/tmp/abcov/ab.profdata -ignore-filename-regex='Views/|SelfTest'
```

## Not covered (manual)

SwiftUI views, `Store`, notifications and their actions, typing into real terminals (AppleScript/tmux),
launching agents in Terminal, git status polling, model-generated text itself.

## Rule

Every behavior change in the core gets a self-test check in the same commit.
