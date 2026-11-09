---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# ADR-006: Built-in `--self-test` instead of XCTest

**Status:** Accepted
**Date:** 2026-11-09
**Authors:** @Malashkin

## Context

The project builds with the Command Line Tools only; `swift test` fails there because XCTest ships with Xcode.

## Decision

Ship end-to-end checks inside the binary: `AgentBoard --self-test` creates a throwaway database, git repository and Claude/Codex folders, exercises the core through the same entry points as real hooks and MCP, prints ✓/✗ and exits with the number of failures. `scripts/test.sh` builds and runs it.

## Consequences

### Positive
- Runs anywhere the app builds; tests real behavior end to end.

### Negative
- No UI tests; no per-test isolation beyond the run.
- No off-the-shelf mutation or coverage tooling: mutation testing is a small script with hand-picked
  mutants (`scripts/mutation-check.py`); coverage uses LLVM tools from the Command Line Tools.

### Follow-up (2026-11-09)
- Checks are grouped into unit / contract / integration layers; property-based checks use a seeded RNG.
- The integration layer includes an end-to-end commit through a real HTTP server, the real bridge and git hooks.

## Alternatives Considered

### Require Xcode for XCTest
- Why rejected: heavier setup for contributors and CI.
