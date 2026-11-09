#!/usr/bin/env python3
"""Hand-picked mutation testing for AgentBoard (no Swift mutation tool works without Xcode).

Each mutant breaks one rule the self-test is supposed to guard. For every mutant: apply it,
build a debug binary into a separate build folder, run `--self-test`, restore the source.
A mutant is KILLED when the self-test fails, SURVIVED when it still passes.
Usage: scripts/mutation-check.py [build-dir] [name-filter]
"""
import os, subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "AgentBoard"
BUILD = sys.argv[1] if len(sys.argv) > 1 else "/tmp/agentboard-mutants"
ONLY = sys.argv[2] if len(sys.argv) > 2 else ""   # optional: run only mutants whose name contains this

MUTANTS = [
    ("folder pattern matches sibling prefix", "Coordination.swift",
     "return path.hasPrefix(dir) }", "return path.hasPrefix(pattern) }"),
    ("own reservations block their holder", "Coordination.swift",
     "let active = activeReservations(project: project).filter { $0.agentId != agentId }",
     "let active = activeReservations(project: project).filter { _ in true }"),
    ("pre-commit never sees a recent intent", "Coordination.swift",
     "now() - intent.at < AppSettings.approvalTimeout + 300", "now() - intent.at > AppSettings.approvalTimeout + 300"),
    ("commit regex accepts commit-tree", "Core.swift",
     r'\s+commit(\s|$)"#', r'\s+commit"#'),
    ("task notifications treated as human prompts", "Core.swift",
     '["<task-notification>", "<system-reminder>"', '["<system-reminder>"'),
    ("time report never joins events into stretches", "AutoTasks.swift",
     "at - p.at <= gap", "at - p.at < 0"),
    ("project mention ignores folder boundary", "Models.swift",
     '!(next.isLetter || next.isNumber || next == "-" || next == "_" || next == ".")', "true"),
    ("slug keeps trailing dash", "Workspaces.swift",
     'return String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))', "return String(out.prefix(40))"),
    ("any finished tool drops pending requests", "Coordination.swift",
     "if let inputKey, e.inputKey != inputKey { continue }", ""),
    ("stuck threshold raised to 4", "Coordination.swift",
     "if same >= 3 {", "if same >= 4 {"),
    ("liveness ends sessions never seen alive", "SessionLiveness.swift",
     "} else if seen.contains(a.sessionId), t - a.lastSeen > 30 {", "} else if t - a.lastSeen > 30 {"),
    ("claim ignores the active owner", "MCPServer.swift",
     'oa.isActive(staleMinutes: AppSettings.staleMinutes), !args.b("force") {', 'oa.isActive(staleMinutes: AppSettings.staleMinutes), false {'),
    ("broadcast includes the sender", "Core.swift",
     "?? activeAgents(project: project).map(\\.id).filter { $0 != from?.id }", "?? activeAgents(project: project).map(\\.id)"),
    ("inbox never marked delivered", "Core.swift",
     'db.query("UPDATE messages SET delivered_at=? WHERE to_agent=? AND delivered_at IS NULL", [now(), agent])', ""),
    ("installer doesn't strip its old hooks", "Integrations.swift",
     'var hooks = strippedHooks(s["hooks"] as? JSON ?? [:])\n        for ev in claudeEvents', 'var hooks = s["hooks"] as? JSON ?? [:]\n        for ev in claudeEvents'),
    ("foreign Host accepted", "Core.swift",
     'if !["127.0.0.1", "localhost", "[::1]"].contains(name) {', "if false {"),
    ("pre-commit guard appended after an exec", "Integrations.swift",
     "lines.insert(preLine, at: 1)", "lines.append(preLine)"),
    ("Codex gets extra decision fields", "Coordination.swift",
     "if e.plain {\n", "if false {\n"),
]

def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)

results = []
for name, file, old, new in MUTANTS:
    if ONLY and ONLY not in name:
        continue
    path = SRC / file
    original = path.read_text()
    if original.count(old) != 1:
        results.append((name, "INVALID (pattern not found exactly once)")); continue
    try:
        path.write_text(original.replace(old, new, 1))
        b = run(["swift", "build", "-c", "debug", "--build-path", BUILD])
        if b.returncode != 0:
            results.append((name, "INVALID (does not compile)")); continue
        t = run([f"{BUILD}/debug/AgentBoard", "--self-test"], timeout=600)
        results.append((name, "KILLED" if t.returncode != 0 else "SURVIVED"))
    finally:
        path.write_text(original)
    print(f"{results[-1][1]:9} {name}", flush=True)

killed = sum(1 for _, r in results if r == "KILLED")
valid = sum(1 for _, r in results if not r.startswith("INVALID"))
print(f"\nmutation score: {killed}/{valid} killed" + (f" ({100 * killed // max(valid, 1)}%)" if valid else ""))
sys.exit(0 if killed == valid else 1)
