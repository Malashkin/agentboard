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

## Alternatives Considered

### Require Xcode for XCTest
- Why rejected: heavier setup for contributors and CI.
