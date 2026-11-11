---
audience: product
owner: @Malashkin
updated: 2026-11-11
---

# Positioning

**AgentBoard works on top of the agents you already run.** It does not launch, host or own them:
Claude Code and Codex keep running in your terminals, and AgentBoard plugs in through their hooks and MCP.

## One sentence

Keep your terminals and your workflow; AgentBoard shows the whole team of agents, keeps them out of each
other's way and lets you answer them from one place.

## Versus agent platforms

[Multica](https://github.com/multica-ai/multica) and [Paperclip](https://github.com/paperclipai/paperclip)
are platforms that *run* agents: tasks go in, the platform launches agents in its own environment.
Paperclip goes further — an autonomous "company" of agents with org charts, budgets and governance.

| | AgentBoard | Agent platforms |
|---|---|---|
| Where agents run | the user's own terminals | inside the platform |
| Setup | one native macOS app, local SQLite | server, database, web UI |
| Human's role | drives the agents directly | assigns tickets, reviews results |
| Strength | live interactive sessions, coordination, visibility | autonomous runs off a queue, team-wide |

## What this means for product decisions

- Never require the user to start an agent *through* AgentBoard; anything started elsewhere must show up by itself.
- Never break the terminal: hooks fail open, a closed AgentBoard changes nothing.
- Prefer features that make the user's own sessions easier to see, answer and coordinate over features that
  replace those sessions.
