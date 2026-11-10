---
audience: all
owner: @Malashkin
updated: 2026-11-10
---

# Data flows

## A Claude Code tool call

```mermaid
sequenceDiagram
  participant A as Claude Code
  participant B as agentboard-hook
  participant S as AgentBoard (Core)
  A->>B: PreToolUse JSON (stdin)
  B->>S: POST /hook/claude?tty=ttysNNN (X-AgentBoard-Token)
  S->>S: find project (pinned → cwd → known session → files mentioned)
  S->>S: record action, check reservation, conflict warning
  alt reserved by another agent
    S-->>B: permissionDecision: deny + reason
  else git commit (approve mode)
    S-->>B: (held until the human decides or timeout → "ask")
  else
    S-->>B: empty or additionalContext
  end
  B-->>A: hook output (stdout)
```

## A permission request answered in the app

```mermaid
sequenceDiagram
  participant A as Claude Code / Codex
  participant S as AgentBoard
  participant H as Human
  A->>S: PermissionRequest (hook held open)
  S->>H: card in "Needs your decision" + notification with actions
  par terminal prompt stays live
    H-->>A: answers in terminal → PostToolUse arrives → request dropped in app
  and
    H->>S: Allow / Deny / answer / approve plan
    S-->>A: decision (Claude: updatedInput for answers; Codex: plain allow/deny)
  end
```

## Reservation enforced on commit

```mermaid
sequenceDiagram
  participant X as Agent B (Bash: git commit)
  participant S as AgentBoard
  participant G as git pre-commit hook
  X->>S: PreToolUse git commit → commitIntent[repo root] = B
  G->>S: POST /hook/git-precommit (root + staged files, token)
  S->>S: staged files ∩ exclusive reservations of other active agents
  S-->>G: refusal text (or empty)
  G-->>X: exit 1 with the message (commit aborted)
```

## From request to task, time and summary

1. `UserPromptSubmit` → `TaskAutopilot`: first work request → new *auto* task (title by Haiku);
   a request about something else → previous task to review, new task.
2. Every event stores the agent's current `task_id`.
3. `timeReport` groups an agent's events into working stretches (gaps ≤ 5 min), by task and client.
4. The evening summary gathers commits, tasks, prompts, answers, notes and the time report and asks `claude -p` for Markdown.
