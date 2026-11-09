---
audience: testing
owner: @Malashkin
updated: 2026-11-09
---

# Running tests

```sh
./scripts/test.sh                       # build (release) + run the self-test
.build/release/AgentBoard --self-test   # run only
```

Output is one line per check (`✓` / `✗ name — detail`) and `N passed, M failed`; the exit code is the
number of failures. Temporary files are removed at the end.

## Isolated manual run

```sh
T=$(mktemp -d)
AGENTBOARD_DATA_DIR=$T/data AGENTBOARD_BRIDGE_DIR=$T/bridge CLAUDE_CONFIG_DIR=$T/claude CODEX_HOME=$T/codex \
  .build/release/AgentBoard -port 7788 &
curl -s 127.0.0.1:7788/health
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/path/to/project"}' 127.0.0.1:7788/hook/claude
```

## Checking the UI

```sh
AGENTBOARD_DATA_DIR=… AGENTBOARD_SNAPSHOT=/tmp/shot.png AGENTBOARD_SNAPSHOT_DELAY=6 \
  dist/AgentBoard.app/Contents/MacOS/AgentBoard -port 7789
```
A copy of the real database in `AGENTBOARD_DATA_DIR` shows real data without touching it.
