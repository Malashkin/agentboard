---
audience: product
owner: @Malashkin
updated: 2026-11-11
---

# Features

## Visibility
- **Agent cards** — one per Claude Code / Codex session, with a unique superhero name (100 built in),
  status (working · waiting for you · idle · stuck · finished · inactive), project, branch, current task,
  touched files, last action and a quick reply field.
  *"Waiting for you" means the agent cannot continue without an answer — a permission, a question,
  a plan. An agent that merely finished its turn and sits at its prompt is **idle**, even though
  Claude Code announces that as "waiting for your input".*
- **Order of the cards** — agents that are working (including ones flagged as looping) come first;
  the rest keep a stable order by session start, so a card moves only when its status really changes.
- **Plain-language status** — a small model (Haiku via `claude -p`) writes one or two sentences about
  what the agent is doing, refreshed only after new activity (default: at most every 2 minutes per agent).
- **Feed** — prompts, commands, edits, reads, searches, subagents, MCP calls, failures, answers, commits.
- **Subagents** shown as lanes under their agent, with description and result.
- **Live session status** from Claude Code's own session files (closed terminal → finished).
- **History** of any day, including sessions and commits from before AgentBoard was installed (imported).
- **Sidebar** shows the date of the last work per project. Right-click a project → *Rename…* (name shown in
  AgentBoard only), *Open in Finder*, *Remove from AgentBoard…* — keep its history (adding the folder again
  restores tasks, feed, notes) or delete it.

## Answering agents
- **Needs your decision** — permission requests (Allow · Deny with comment · Allow for this session),
  questions with the agent's options or a free answer, plans (Approve · Request changes), commits.
  Also in the menu bar and as macOS notifications with action buttons. The terminal prompt stays live.
- **Reply** on an idle/waiting agent's card or from its notification — typed into its terminal
  (herdr, tmux, iTerm2, Terminal.app); queued into context for a busy agent; background resume for closed sessions.
- **While you were away** — a short digest after a break (default 20 minutes).

## Coordination
- Agents get a digest of their neighbours at session start and on new requests.
- MCP server `agentboard`: look at another agent's activity, message agents, post notes, manage tasks.
- **File reservations** with expiry; edits of someone else's reservation are denied; a git pre-commit
  hook refuses an agent's commit that touches them. Human commits are never blocked.
- **Conflict warnings** when an agent edits a file another agent changed recently.
- **Stuck detection** with a notification and a nudge to the agent.
- **Commit control** — log, notify, or require approval.
- **Pin a session to a project** when it was started outside the project folder.

## Tasks, clients, time
- **Kanban** (Backlog · In progress · In review · Done) with a client per task.
- **Automatic tasks** from the agents' real requests (title by Haiku); new topic → previous task to review;
  session end → task to review.
- **Time** per client and per task from agent activity (idle gaps excluded), wall-clock and agent time.
- **Task worktrees** — "Start agent" creates a branch and a worktree, opens a terminal with Claude Code
  or Codex; review the diff with line comments sent back to the agent; merge, open a PR, remove the worktree.
- **Evening summary** in Markdown — highlights, per project, per client with time, unfinished, needs attention.

## Personalization
- 8 color schemes, accent color, light/dark, density, card style, animations.
- Widget dashboards (Overview and per project): drag, resize, hide, add.
- English UI; Russian input from the human is understood.
