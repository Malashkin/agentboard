---
audience: backend
owner: @Malashkin
updated: 2026-11-09
---

# Local JSON API

Scripting interface used by the self-test and for automation. Same rules as the rest of the server
(see [overview.md](overview.md)).

### Board

```http
GET /api/board
```
`200` text/plain — the board of every project as agents see it.

### Pending decisions

```http
GET /api/pending
```
```json
{"pending":[{"id":"E948…","kind":"question","agent":"Batman","project":"repo","summary":"Which DB?",
  "questions":[{"question":"Which DB?","options":["Postgres","SQLite"]}]}]}
```

### Decide

```http
POST /api/decide
Content-Type: application/json

{"id":"E948…","allow":true,"comment":"","answers":{"Which DB?":"SQLite"},"always":false}
```
Same as the buttons in the app. `404` if the request is gone.

### Create a task

```http
POST /api/tasks
{"project_path":"/Users/me/dev/app","title":"Write CHANGELOG.md","details":"…","client":"Acme"}
```
`200` `{"id":2,"title":"…"}` · `400` unknown project or missing title.

### Launch an agent on a task

```http
POST /api/tasks/launch
{"task_id":2,"tool":"claude","isolated":true}
```
Creates the worktree (when `isolated`), opens Terminal/iTerm2 with the agent and the task prompt.
`200` `{"ok":true,"result":"Agent launched in … (branch agent/2-…)."}` · `404` · `500` with `error`.
