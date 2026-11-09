---
audience: devops
owner: @Malashkin
updated: 2026-11-09
---

# Build and install

## Requirements
macOS 14+, Command Line Tools (`xcode-select --install`). Optional: `gh` (pull requests), `tmux`, iTerm2.

## Build

```sh
swift build -c release                 # binary in .build/release/AgentBoard
./scripts/build-app.sh                 # dist/AgentBoard.app (icon, Info.plist, ad-hoc signature)
./scripts/build-app.sh --install       # also copies to /Applications
```

The icon is rendered by `scripts/make-icon.swift` and cached in `dist/AppIcon.icns` (delete to regenerate).
Bundle id `app.agentboard.mac`, version in the script's Info.plist.

## Update

Quit the app, run `./scripts/build-app.sh --install`, open it again. The bridge script and git hooks are
refreshed at launch. After changes to hook events, run **Integrations → Connect** (or
`AgentBoard --install-claude`) and restart agent sessions.

## Uninstall

1. Integrations → disconnect, or `AgentBoard --uninstall-claude`.
2. Remove `~/.codex/hooks.json` entries containing `agentboard-hook` and `[mcp_servers.agentboard]` from `~/.codex/config.toml`.
3. Remove project git hook lines containing `agentboard-hook` (project settings → remove).
4. Delete `/Applications/AgentBoard.app`, `~/.agentboard`, `~/Library/Application Support/AgentBoard`.

## Release

Builds are signed ad hoc and not notarized; they are meant for the machine that built them.
