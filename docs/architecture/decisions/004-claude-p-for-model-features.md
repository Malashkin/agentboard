---
audience: all
owner: @Malashkin
updated: 2026-11-09
---

# ADR-004: `claude -p` (no tools) for plain-language features

**Status:** Accepted
**Date:** 2026-11-09
**Authors:** @Malashkin

## Context

Narratives, task titles, the away digest and the summary need a language model. The user already has a Claude Code login; managing API keys inside the app is extra risk.

## Decision

Call the installed `claude` CLI in print mode with `--model haiku --tools "" --safe-mode --no-session-persistence`, input on stdin, from the app's support folder, with Claude Code session variables stripped. Every feature can be turned off; test mode never calls a model.

## Consequences

### Positive
- No API keys in the app; uses the user's subscription.
- No tools → injected text can't make the model act.

### Negative
- Activity text goes to Anthropic.
- (Resolved 2026-11-09) The evening summary now uses the same restricted arguments (`Shell.modelArgs`).

## Alternatives Considered

### Direct API calls
- Why rejected: requires key management and billing setup.
