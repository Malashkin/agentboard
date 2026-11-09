#!/bin/bash
# Builds and runs AgentBoard's built-in end-to-end checks (temporary data, never touches yours).
set -e
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | grep -E "error:|Compiling|Build" | grep -v xcrun || true
.build/release/AgentBoard --self-test
