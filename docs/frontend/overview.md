---
audience: frontend
owner: @Malashkin
updated: 2026-11-09
---

# Frontend overview

## Shell

- `AgentBoardApp` — `Window("main")`, `MenuBarExtra` (window style), `Settings` scene; CLI flags handled in `init`.
- `AppDelegate` — starts the core, server, watchers, notifications; wires `Core` callbacks to `Notifier`, `TaskAutopilot`, `Store`.
- `MainView` — sidebar (Overview, History, Summaries, Integrations, projects with last-work date) and detail;
  banners: server errors, *While you were away*, *Needs your decision* (outside dashboards).

## State

`Store` (`ObservableObject`, main thread) holds the published arrays (projects, agents, tasks, events,
files, summaries, pending, messages, reservations, subagents, lastWork, awayDigest). It reloads from
`Core.snapshot()` on change notifications (debounced 0.6 s) and **assigns only arrays that changed**.
A 5-second ticker updates `now` for relative times. Settings use `@AppStorage` with keys from `Pref`.

## Rendering rules (do not break)

These fixed visible flicker and lost input in the past:

1. **Stable identities.** Default dashboard layouts use fixed widget UUIDs (`LayoutStore.defaults`).
   Never create ids in computed properties that run on every render.
2. **No global animation on data refresh.** `Store.apply` runs without `withAnimation`. Lists animate
   only when their membership changes: `.animateRows(ids)` + `.feedRowTransition()`.
3. **No slide transitions in lazy stacks.** Row transitions are a short fade + 6 pt offset; removals are instant.
4. **Fixed-height containers scroll.** The feed widget is a `ScrollView` of fixed height; widgets clip their content.
5. **Cards don't change height** when text changes (`lineLimit(n, reservesSpace: true)`).
6. Numbers use `.smoothNumber(value)` (numeric content transition).
7. Agent cards are ordered by session start, not by activity — they must not jump under the cursor.

## Theming

`ThemeStore` (`Theme.swift`): presets, accent, appearance, density, card style, animations; `ThemeStore.anim()`
returns nil when animations are off.
