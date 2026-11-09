---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# ADR-003: SQLite behind one serial queue, snapshots to the UI

**Status:** Accepted
**Date:** 2026-11-09
**Authors:** @Malashkin

## Context

Events arrive concurrently from hooks, MCP, watchers and the UI; correctness matters more than throughput (dozens of events per second at most).

## Decision

All database access and mutable `Core` state live on `Core.shared.q`, a serial queue. The UI never queries the database directly: `Store.reload()` takes a `Snapshot` on the queue (debounced 0.6 s) and publishes only the arrays that changed.

## Consequences

### Positive
- No locking bugs; simple code.
- Publishing only changes keeps SwiftUI from redrawing everything.

### Negative
- Long work must not run on the queue (git, model calls and terminal work run elsewhere and hop back).

## Alternatives Considered

### Core Data / GRDB
- Why rejected: extra framework or dependency for a small schema.
