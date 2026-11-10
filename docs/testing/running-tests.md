---
audience: testing
owner: @Malashkin
updated: 2026-11-10
---

# Running tests

```sh
./scripts/test.sh                       # build (release) + run the self-test
.build/release/AgentBoard --self-test   # run only
```

Output is one line per check (`✓` / `✗ name — detail`) grouped by layer (`[unit]`, `[contract]`,
`[integration]`), a per-layer summary and `N passed, M failed`; the exit code is the number of failures.
Temporary files are removed at the end. The run is deterministic and takes about 15 seconds.

## Suggested-projects scan

```sh
.build/release/AgentBoard --discover   # read-only: suggestions, time, bytes read, git calls
CLAUDE_CONFIG_DIR=/path/to/fake/claude CODEX_HOME=/path/to/fake/codex .build/release/AgentBoard --discover
```

## Mutation gate

```sh
scripts/mutation-check.py /tmp/agentboard-mutants   # ~10–15 min; restores sources after each mutant
```
Don't edit sources while it runs. Every mutant must be KILLED; add or strengthen a check for any survivor.

## Isolated manual run

```sh
T=$(mktemp -d)
AGENTBOARD_DATA_DIR=$T/data AGENTBOARD_BRIDGE_DIR=$T/bridge CLAUDE_CONFIG_DIR=$T/claude CODEX_HOME=$T/codex \
  .build/release/AgentBoard -port 7788 &
curl -s 127.0.0.1:7788/health                      # the only route without the token
curl -s -X POST -H 'Content-Type: application/json' -H @$T/bridge/auth-header \
  --data '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/path/to/project"}' 127.0.0.1:7788/hook/claude
```

## Checking the UI

```sh
AGENTBOARD_DATA_DIR=… AGENTBOARD_SNAPSHOT=/tmp/shot.png AGENTBOARD_SNAPSHOT_DELAY=6 \
  dist/AgentBoard.app/Contents/MacOS/AgentBoard -port 7789
```
A copy of the real database in `AGENTBOARD_DATA_DIR` shows real data without touching it. Always set
`AGENTBOARD_BRIDGE_DIR` to a temp folder too; with either variable set the instance leaves the real MCP registrations
and project git hooks alone.
