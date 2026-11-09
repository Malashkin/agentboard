---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# ADR-001: Native SwiftUI app with no third-party dependencies

**Status:** Accepted
**Date:** 2026-11-09
**Authors:** @Malashkin

## Context

The tool must feel like a real Mac app (menu bar, notifications, AppleScript, launch at login) and be buildable on a machine with only the Command Line Tools.

## Decision

Build a native SwiftUI app with SwiftPM, using only system frameworks (SQLite via libsqlite3, Network.framework, UserNotifications). The `.app` bundle is assembled by `scripts/build-app.sh` and signed ad hoc.

## Consequences

### Positive
- Small, fast, no supply-chain risk, no runtime to install.
- Full access to macOS integrations.

### Negative
- No XCTest without Xcode (see ADR-006).
- Not notarized; distribution beyond the author's Mac needs signing work.

## Alternatives Considered

### Electron / web UI
- Pros: cross-platform.
- Why rejected: heavy, weaker OS integration, dependency surface.
