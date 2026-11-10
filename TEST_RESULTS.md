# Test Results

**Date:**     2026-11-10 09:40 (security audit closed: H2, M2, L1–L3; projects rename/remove; CPU fix)
**Commit:**   c602b06 + working tree
**Stack:**    Swift 5.9 / SwiftPM · runner: `./scripts/test.sh` (`AgentBoard --self-test`; XCTest unavailable without Xcode — ADR-006)
**App type:** native macOS desktop app with a local HTTP / MCP API (no web UI → no browser e2e)
**Shape:**    integration-heavy (Testing Trophy): most risk lives in the wiring between hooks, the server, the DB, git and the filesystem
**Status:**   🟢 PASS

## This run
- New suites: `hardeningSuite` (MCP identity by id, self-chosen names, token/prompt file permissions, launch command,
  MCP registrations with the token, **server limits on a real socket**) and `projectsSuite` (rename, remove keeping
  history, restore by re-adding, remove and delete). New unit and contract sections for H2/M2/L2.
- Regression for H2: the audit PoC (`"agent_id": "Batman"`) is refused both without a token (401) and, with the token,
  by name (`don't know who you are`); verified live against the installed app (401 / 200 with token / 403 scripting off / 413).

| Layer | Tests | Passed | Failed |
|---|---|---|---|
| Unit | 99 | 99 | 0 |
| Contract | 41 | 41 | 0 |
| Integration | 122 | 122 | 0 |
| E2E (browser) | N/A — not a web UI; the end-to-end commit through the real bridge (now sending the token) + git is in Integration | | |

## Mutation gate (headline signal)

| Metric | Value |
|---|---|
| Mutants | 39 (19 `[sec]`: each re-introduces an audit finding; 2 for projects) |
| Killed | 39 |
| Score | 100% |

- Survivor found and fixed: **"[sec] H2 token compare is a prefix match"** — the wrong-token test used a reversed token,
  never a prefix of the real one. Added "a truncated token (a prefix of the real one) → 401"; killed.
- Script fix: mutants in `Views/` need the subfolder in their path.

## Not covered by automated tests
- Removing the foreground check at its call site in `typeIntoTerminal` (needs a real terminal).
- CPU use of the UI (measured by hand: before ~25–31% CPU, ~740 idle wake-ups/s with a working agent and the
  window open; after 0–7%, ~5 wake-ups/s).
- The Settings toggle and sidebar menus (SwiftUI; checked by building and by hand).

---

# Previous run (2026-11-09)

## Changed files
- `Sources/AgentBoard/SelfTest.swift` — per-layer accounting, new checks
- `Sources/AgentBoard/SelfTestSuites.swift` (new) — unit, contract, integration and gap suites
- `Sources/AgentBoard/Integrations.swift` — fix: bridge port file, config paths honour `CLAUDE_CONFIG_DIR` / `CODEX_HOME`
- `Sources/AgentBoard/Workspaces.swift` — fix: slug trimmed after cutting
- `Sources/AgentBoard/Core.swift` — fix: legacy names containing digits
- `Sources/AgentBoard/MCPServer.swift` — fix: `register_agent` refuses folders outside projects
- `Sources/AgentBoard/SessionLiveness.swift`, `SessionDelivery.swift` — `tick` / `run` made internal for tests
- `scripts/mutation-check.py` (new)

## Test Summary

| Layer | Tests | Passed | Failed |
|---|---|---|---|
| Unit | 76 | 76 | 0 |
| Contract | 31 | 31 | 0 |
| Integration | 82 | 82 | 0 |
| E2E (browser) | N/A — not a web UI; the end-to-end commit through the real bridge + git is in Integration | | |

Runs are deterministic (property checks use a seeded generator); three consecutive runs gave identical results.

## Test quality — Mutation gate (headline signal)

| Metric | Value |
|---|---|
| Mutants generated | 23 (hand-picked; 5 of them re-introduce H1/M1/M3) |
| Mutants killed | 23 |
| Mutation score | 100% |
| Surviving (open) | 0 |
| Surviving (justified) | 0 |

- **Tool:** `scripts/mutation-check.py` (no Swift mutation tool works without Xcode).
- First pass: 17/18. Survivor "Codex gets extra decision fields" (`Coordination.swift`, `if e.plain {` → `if false {`) — the only Codex test used a Bash request, where the plain branch makes no difference. Added "Codex never gets updatedInput, even for a plan"; the mutant is now killed.

## Coverage (diagnostic only — NOT a goal)

Line coverage of the core (excluding Views, SelfTest, Theme, Logo): ~45% before this run.
Gaps that were risky and are now covered: `SessionLiveness` (was 0%), MCP tool rules, `SessionDelivery` inbox path,
summary / narrator / away-digest inputs. Remaining uncovered by design: `Store`, `Notifier`, SwiftUI views,
AppleScript/tmux typing, `GitMonitor` polling, model calls.

## Output (excerpts)

```
[unit] Branch slugs and shell quoting
  ✓ Cyrillic is transliterated
  ✓ property: slugs are safe for paths and branches ([a-z0-9-], ≤40, no leading/trailing/double -)
  ✓ property: shell-quoted strings reach the program unchanged (60 random strings)
[integration] End to end through the bridge: real git commit vs a reservation
  ✓ test server listening
  ✓ an agent's commit touching another agent's reservation is refused by git
  ✓ the human's own commit goes through
  ✓ post-commit hook reports the commit to the board
unit: 61 passed, 0 failed
contract: 22 passed, 0 failed
integration: 82 passed, 0 failed
```

## Failures (found and fixed in this run)

### ❌ Bridge reads the port from ~/.agentboard regardless of its own folder
- **Layer:** integration · **Test:** "an agent's commit touching another agent's reservation is refused by git"
- **Error:** commit went through (exit 0) — the hook talked to the real app on 7777, not the test server
- **Fix:** code — the bridge reads `port` next to its `bin/` folder

### ❌ Installers ignore CLAUDE_CONFIG_DIR / CODEX_HOME
- **Layer:** integration · **Tests:** "Claude settings path follows CLAUDE_CONFIG_DIR", "Codex paths follow CODEX_HOME"
- **Error:** `/Users/mike/.claude/settings.json` — an isolated `--install-claude` would edit the real settings (the test refuses to write when the path is outside the test folder)
- **Fix:** code — paths derived from the environment like Claude Code / Codex do

### ❌ Slug can end with a dash
- **Layer:** unit (property) · **Fix:** code — trim after cutting to 40 characters

### ❌ "Икс-23" not migrated to "X-23"
- **Layer:** unit · **Fix:** code — exact legacy name tried before splitting a "-N" suffix

### ❌ register_agent from an unrelated folder attached to the only project
- **Layer:** integration · **Fix:** code — only a cwd match or an explicit `project_path`

### ❌ "installed once, existing hook kept"
- **Layer:** integration · **Fix:** test — the bridge path itself contains "agentboard-hook"; count hook lines instead

## Security fixes (H1, M1, M3)
- Regression tests: "a look-alike origin (127.0.0.1.evil.example) is refused", "localhost.evil.example is refused",
  "text/plain POST → 415", "M1: the evening summary runs claude without tools…", "M3: shell in the foreground → don't type".
  The H1 case was reproduced red against the live app before the fix (`200` for the look-alike origin) and is `403` after.
- Mutants re-introducing each issue (`[sec]` in `scripts/mutation-check.py`): 5/5 killed.
- Not covered by an automated test: removing the foreground check at its call site in `typeIntoTerminal` (needs a real terminal).

## Notes
- New test files: `Sources/AgentBoard/SelfTestSuites.swift`, `scripts/mutation-check.py`
- Regression-first: the bridge-port, installer-path, slug and legacy-name tests were run red before the fixes and green after.
- Flagged, not frozen: `isWorkRequest` treats requests shorter than 15 characters as non-work ("fix login" → no auto task) — product decision needed.
- Flagged, not frozen: `git` command detection also matches the text `git commit` inside other commands (e.g. `echo "git commit"`); harmless (only triggers the commit flow) and left untested on purpose.
