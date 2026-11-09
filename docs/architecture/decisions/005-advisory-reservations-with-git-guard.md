---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# ADR-005: Advisory file reservations enforced by hooks and git pre-commit

**Status:** Accepted
**Date:** 2026-11-09
**Authors:** @Malashkin

## Context

Parallel agents overwrite each other's work. Hard locks on files are impossible (agents edit files directly) and would block the human.

## Decision

Agents lease files/folders/globs with an expiry (`reserve_files`). Enforcement happens at the agent boundary: `PreToolUse` denies edits of someone else's exclusive reservation (Claude Edit/Write, Codex apply_patch), and a git pre-commit hook refuses commits by an agent whose staged files hit another agent's reservation. Human commits are never blocked; leases end with the session.

## Consequences

### Positive
- Prevents the common collision cases without blocking the human.
- Works for Claude Code and Codex.

### Negative
- Advisory: `git commit --no-verify` or editing via shell commands bypasses it.

## Alternatives Considered

### No reservations, warnings only
- Why rejected: warnings alone didn't stop overwrites.
