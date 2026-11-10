---
audience: product
owner: @Malashkin
updated: 2026-11-10
---

# Glossary

| Term | Meaning |
|---|---|
| Agent | One Claude Code or Codex session, shown as a card with a superhero name |
| Session | The agent's conversation in one terminal; identified by Claude/Codex `session_id` |
| Turn | One request → work → answer cycle of an agent |
| Subagent | A helper agent a Claude session starts (Explore, Plan, …), shown as a lane |
| Status: waiting for you | The agent needs a human decision or input |
| Status: stuck | The agent repeats a failing or identical action (see stuck detection) |
| Status: inactive | No activity for the configured time (default 30 min) and no live process seen |
| Reservation | A time-limited lease on files/folders/globs; others can't edit or commit them |
| Needs your decision | Pending permission requests, questions, plans and commit approvals |
| Auto task | A board task created from an agent's request (marked "auto") |
| Wall time / agent time | Real elapsed working time (parallel work counted once) / sum over agents |
| Task worktree | A git worktree + branch `agent/<id>-<slug>` created for a task |
| Narrative | The plain-language line about what an agent is doing |
| Client | Who the work is for; set on a project (default) or per task |
| Archived project | A project removed with *keep its history*: hidden from the dashboard, its data kept; adding the same folder again restores it |
| Token | The per-install secret in `~/.agentboard/token`; every local request except `GET /health` must present it |
