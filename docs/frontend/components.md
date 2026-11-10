---
audience: frontend
owner: @Malashkin
updated: 2026-11-10
---

# Views and components

| View | File | Purpose |
|---|---|---|
| Overview / project dashboards | `Views/Dashboard.swift`, `Views/ProjectViews.swift` | Widget grid (stats, decisions, agents, feed, tasks, time, reservations, commits, clients, hot files, summary); edit mode with drag & drop |
| Agent cards and details | `Views/AgentViews.swift` | Card (narrative, stuck banner, subagents, reservations, quick reply), detail sheet (pin to project, timeline), message sheet |
| Board | `Views/BoardView.swift` | Kanban, task editor (with *Agent & worktree* section) |
| Worktree & review | `Views/WorkspaceViews.swift` | Start agent, branch actions, review sheet with diff and line comments |
| History | `Views/HistoryView.swift` | Any day: stats, time, clients, per-agent timelines |
| Time | `Views/TimeViews.swift` | Time per client/task |
| Main, banners, approvals | `Views/MainView.swift` | Sidebar, *While you were away*, approval rows (commit/permission/question/plan) |
| Settings, menu bar, integrations, summaries | `Views/OtherViews.swift` | |
| Shared | `Views/Components.swift` | `StatusBadge`, `Pill`, `Card`, `StatTile`, `MarkdownView`, `smoothNumber`, `animateRows`, `feedRowTransition`; `MarkdownView.unlinked` shows links as plain text with the URL |
| Theme | `Theme.swift` | Colors, `PulseDot` (the "working" pulse — a Core Animation layer via `PulseRing`, never a SwiftUI `repeatForever`, see [overview.md](overview.md#performance-rules)) |
