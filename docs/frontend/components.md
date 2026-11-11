---
audience: frontend
owner: @Malashkin
updated: 2026-11-11
---

# Views and components

| View | File | Purpose |
|---|---|---|
| Overview / project dashboards | `Views/Dashboard.swift`, `Views/ProjectViews.swift` | Widget grid (stats, decisions, agents, feed, tasks, time, reservations, commits, clients, hot files, summary); edit mode with drag & drop |
| Agent cards and details | `Views/AgentViews.swift` | Card (narrative, stuck banner, subagents, reservations, quick reply, *Terminal* and *Message* buttons, context menu with briefings), detail sheet (pin to project, timeline, *Replay*), message sheet |
| Replay | `Views/ReplayView.swift` | Step-by-step session replay: slider, play, request chapters, since-I-was-away, diff of every edit |
| Needs-you panel, terminal focus, hot keys | `QuickAccess.swift` | `TerminalFocus` (tmux / herdr / iTerm2 / Terminal.app), `Attention` queue, `HotKeys`, floating `QuickPanel` |
| Project memory | `Views/ProjectViews.swift` (`MemoryView`) | *Memory* tab: list, add, remove |
| Phone settings | `Views/OtherViews.swift` (`PhoneSettings`) | Telegram bot connect, pairing code, "only when away" |
| Board | `Views/BoardView.swift` | Kanban, task editor (with *Agent & worktree* section) |
| Worktree & review | `Views/WorkspaceViews.swift` | Start agent, branch actions, review sheet with diff and line comments |
| History | `Views/HistoryView.swift` | Any day: stats, time, clients, per-agent timelines |
| Time | `Views/TimeViews.swift` | Time per client/task |
| Main, banners, approvals | `Views/MainView.swift` | Sidebar, *While you were away*, approval rows (commit/permission/question/plan) |
| Settings, menu bar, integrations, summaries | `Views/OtherViews.swift` | |
| Shared | `Views/Components.swift` | `StatusBadge`, `Pill`, `Card`, `StatTile`, `MarkdownView`, `smoothNumber`, `animateRows`, `feedRowTransition`; `MarkdownView.unlinked` shows links as plain text with the URL. Hover feedback: button styles `.hover` (icons), `.hoverBordered` (the default, set at each window root with `.hoverButtons()`), `.hoverProminent`, `.hoverRow`; `.hoverHighlight()` for tappable cards; `PointerCursor`. Use these instead of `.borderless` / `.bordered` / `.plain` so everything clickable reacts to the pointer |
| Theme | `Theme.swift` | Colors, `PulseDot` (the "working" pulse — a Core Animation layer via `PulseRing`, never a SwiftUI `repeatForever`, see [overview.md](overview.md#performance-rules)) |
