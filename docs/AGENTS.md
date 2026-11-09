---
audience: all
owner: @Malashkin
updated: 2026-11-09
applies-to: d4917f9
---

# AgentBoard — Agent & Contributor Guide

AgentBoard is a native macOS app (SwiftUI) that acts as mission control for several AI coding
agents — Claude Code and Codex sessions — working on the same projects. It records everything they
do through hooks and an MCP server on `127.0.0.1:7777`, lets the human answer them from one place,
coordinates them (file reservations, stuck detection, messages), and reports the day per project and client.

## Documentation map

| Area | Audience | Path |
|---|---|---|
| What it is, features, roadmap, glossary | product | [product/](product/index.md) |
| System context, data flows, decisions (ADRs) | all | [architecture/](architecture/index.md) |
| Core engine, local HTTP API, hooks, MCP, data model | backend | [backend/](backend/index.md) |
| SwiftUI app: windows, state, rendering rules | frontend | [frontend/](frontend/index.md) |
| Build, install, configuration, integrations | devops | [devops/](devops/index.md) |
| Self-test and how to verify changes | testing | [testing/](testing/index.md) |
| Threat model and open security issues | all | [security/](security/index.md) |
| Where data and logs live, diagnostics | devops | [monitoring/](monitoring/index.md) |
| Change history | all | [CHANGELOG.md](CHANGELOG.md) |

## Quick start

1. Requirements: macOS 14+, Command Line Tools (`xcode-select --install`). Xcode is not needed.
2. Build and install: `./scripts/build-app.sh --install` (copies `AgentBoard.app` to `/Applications`).
3. In the app: **Integrations → Connect** (Claude Code / Codex), then **Add project**.
4. Restart open Claude Code sessions so they pick up the hooks and the MCP server.

## Commands

| Task | Command |
|---|---|
| Build (debug) | `swift build` |
| Build (release) | `swift build -c release` |
| Build the .app bundle | `./scripts/build-app.sh` → `dist/AgentBoard.app` |
| Build + install to /Applications | `./scripts/build-app.sh --install` |
| Test (self-test, 189 checks) | `./scripts/test.sh` (or `.build/release/AgentBoard --self-test`) |
| Mutation gate | `scripts/mutation-check.py /tmp/agentboard-mutants` |
| Run a debug instance | `.build/debug/AgentBoard -port 7788` |
| Run fully isolated | `AGENTBOARD_DATA_DIR=/tmp/ab AGENTBOARD_BRIDGE_DIR=/tmp/ab/bridge CLAUDE_CONFIG_DIR=/tmp/ab/claude CODEX_HOME=/tmp/ab/codex .build/debug/AgentBoard -port 7788` |
| Install integrations from CLI | `/Applications/AgentBoard.app/Contents/MacOS/AgentBoard --install-claude [--install-codex]` |
| Lint / format | none configured (follow the conventions below) |
| Typecheck | the Swift compiler (`swift build`) |

`swift test` does **not** work here: XCTest ships only with Xcode. Tests live in the app as `--self-test`.

## Coding conventions

- Swift 5.9, SwiftUI, macOS 14 APIs. No third-party dependencies — keep it that way (system SQLite, Network.framework).
- **Threading:** everything that touches the database or `Core` state runs on `Core.shared.q` (a serial queue).
  UI state lives in `Store` (main thread) and is refreshed from `Core.snapshot()`.
- **SQL:** always parameterized (`db.query(sql, [args])`); interpolate only constant table/column names.
- **Processes:** `Shell.run(exe, [args])` — argv arrays, never a shell string. The only shell command
  (Terminal launch in `Workspaces`) quotes every value with `shq`.
- **Model calls** (`claude -p`): always `--tools "" --safe-mode --no-session-persistence` unless there is a reason not to.
- **UI text and agent-facing text are English.** Accept Russian input where the human types (e.g. `"все"` in `send_message`).
- Comments explain *why*; keep them short. One feature per file where practical (see [backend/overview.md](backend/overview.md)).
- Commits: imperative summary line; docs and the CHANGELOG are updated in the same commit/PR as the code.

## Do not edit / generated zones

| Path / pattern | Why |
|---|---|
| `.build/`, `dist/` | Build output (SwiftPM, `scripts/build-app.sh`) |
| `dist/AppIcon.icns` | Cached icon; delete it to regenerate from `scripts/make-icon.swift` |
| `docs/assets/logo.png` | Rendered by `swift scripts/make-icon.swift <iconset> docs/assets/logo.png` |
| `~/.agentboard/bin/agentboard-hook` | Rewritten by the app at every launch from `Integrations.hookScript` |
| Entries containing `agentboard-hook` in `~/.claude/settings.json`, `~/.codex/hooks.json`, repo git hooks | Managed by the app's installers |
| `SECURITY_AUDIT_REPORT.md` | Confidential, git-ignored on purpose |

## Known gotchas

- **New hooks need new sessions.** Claude Code reads hooks and MCP servers at session start; restart sessions after (re)installing.
- **Workspace trust.** Claude Code withholds hooks in a folder until you accept its trust dialog — every new task worktree asks once.
- **`xcrun: error: unable to lookup item 'PlatformPath'`** during builds is harmless with Command Line Tools.
- **Launching the app from a Claude Code terminal** passes `CLAUDE_CODE_*` variables to it; `Shell.cleanEnvironment` strips them for child `claude` runs.
- **Test mode:** when `AGENTBOARD_DATA_DIR` is set the app never calls a model and never auto-writes summaries.
- **SwiftUI identity:** default dashboard layouts must keep stable widget ids, and snapshots must not be applied inside a global animation — both caused flicker and lost input before (see [frontend/overview.md](frontend/overview.md)).
- **Paths:** compare repository roots via `git rev-parse --show-toplevel` (`Core.repoRoot`) — `/var/…` vs `/private/var/…` and moved folders otherwise break matching.
- **Claude's session files** store `procStart` in UTC (`SessionLiveness.isAlive` handles both).
- Changing the port requires re-registering the MCP server (Integrations → Connect).
- **Isolated runs:** set `AGENTBOARD_DATA_DIR`, `AGENTBOARD_BRIDGE_DIR`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME` together —
  the bridge then uses its own port file and installers edit only the test folders.
- The self-test starts a real HTTP server on a spare port (27700–27759) and runs real `git commit`s in a temp repo.
