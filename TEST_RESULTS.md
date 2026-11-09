# Test Results

**Date:**     2026-11-09 18:49
**Commit:**   255e56e + working tree (tests and fixes from this run)
**Stack:**    Swift 5.9 / SwiftPM · runner: `./scripts/test.sh` (`AgentBoard --self-test`; XCTest unavailable without Xcode — ADR-006)
**App type:** native macOS desktop app with a local HTTP / MCP API (no web UI → no browser e2e)
**Shape:**    integration-heavy (Testing Trophy): most risk lives in the wiring between hooks, the server, the DB, git and the filesystem
**Status:**   🟢 PASS

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
| Unit | 61 | 61 | 0 |
| Contract | 22 | 22 | 0 |
| Integration | 82 | 82 | 0 |
| E2E (browser) | N/A — not a web UI; the end-to-end commit through the real bridge + git is in Integration | | |

Runs are deterministic (property checks use a seeded generator); three consecutive runs gave identical results.

## Test quality — Mutation gate (headline signal)

| Metric | Value |
|---|---|
| Mutants generated | 18 (hand-picked on the riskiest rules) |
| Mutants killed | 18 |
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

## Notes
- New test files: `Sources/AgentBoard/SelfTestSuites.swift`, `scripts/mutation-check.py`
- Regression-first: the bridge-port, installer-path, slug and legacy-name tests were run red before the fixes and green after.
- Flagged, not frozen: `isWorkRequest` treats requests shorter than 15 characters as non-work ("fix login" → no auto task) — product decision needed.
- Flagged, not frozen: `git` command detection also matches the text `git commit` inside other commands (e.g. `echo "git commit"`); harmless (only triggers the commit flow) and left untested on purpose.
