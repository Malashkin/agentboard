---
audience: product
owner: @Malashkin
updated: 2026-11-09
---

# Product overview

## The problem

People increasingly run several AI coding agents at once — a few Claude Code terminals on one
repository, a Codex session on another. That breaks down quickly:

- **No visibility.** Each agent lives in its own terminal tab; knowing who does what means tabbing
  through windows and scrolling through tool output.
- **Agents collide.** They don't know about each other: two edit the same file, one overwrites the other.
- **Silent waiting.** A permission prompt, a question or a plan to approve sits in a background tab for twenty minutes.
- **Commits behind your back** — on the wrong branch or with files another agent was still changing.
- **No account of the day.** What was done per project and per client is scattered across closed sessions.
- **Loops.** The same failing command again and again, burning time and limits.

## The solution

AgentBoard is a native Mac app that sits next to the agents:

1. **Sees everything** — every session is an agent card with status, task, files and a plain-language
   line about what it's doing; every action is recorded; past sessions are imported.
2. **Lets the human answer in one place** — permissions, questions, plans and commits on the dashboard,
   in the menu bar and in actionable notifications; replies typed straight into an agent's terminal.
3. **Coordinates agents** — they are told about each other, can message each other, reserve files
   (enforced on edits and commits), and get stopped when they loop.
4. **Accounts for the work** — tasks created from real requests, time per client and task, a
   "while you were away" digest and an evening summary.

## Who it is for

Developers and small teams who run several Claude Code / Codex sessions in parallel on macOS and
need to stay in control without babysitting terminals — including freelancers who report work per client.

## Principles

- Local-first: data stays on the Mac (SQLite), the server listens on `127.0.0.1` only.
- Never in the agents' way: if the app isn't running, hooks do nothing.
- Real data only — no demo content.
- Agents and humans are both first-class readers of the board.
