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
    ("[sec] H1 look-alike Origin accepted (old prefix check)", "Core.swift",
     'if req.headers["origin"] != nil {',
     'if let origin = req.headers["origin"], !origin.hasPrefix("http://127.0.0.1"), !origin.hasPrefix("http://localhost") {'),
    ("[sec] H1 browser-simple POST accepted", "Core.swift",
     'if req.method == "POST", Self.isBrowserSimpleContentType(req.headers["content-type"]) {', "if false {"),
    ("[sec] M1 summary runs with tools", "SummaryService.swift",
     "static var modelArguments: [String] { Shell.modelArgs(model: AppSettings.summaryModel) }",
     'static var modelArguments: [String] { ["-p", "--output-format", "text"] }'),
    ("[sec] M3 typing ignores the foreground flag", "SessionDelivery.swift",
     'guard f.count == 2, f[0].contains("+") else { return false }', "guard f.count == 2 else { return false }"),
    ("[sec] M3 any tty name accepted", "Core.swift",
     's.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil', 's.hasPrefix("ttys")'),
    ("[sec] H2 no token check", "Core.swift",
     'if !(req.method == "GET" && req.path == "/health"), !Auth.isAuthorized(req.headers) {', "if false {"),
    ("[sec] H2 token compare is a prefix match", "Auth.swift",
     "return constantTimeEqual(p, token)", "return !p.isEmpty && token.hasPrefix(p)"),
    ("[sec] H2 scripting routes always on", "Core.swift",
     "if Self.humanOnlyRoutes.contains(req.path), !AppSettings.scriptingAPI {", "if false {"),
    ("[sec] H2 caller identified by name", "MCPServer.swift",
     'if let aid = args.str("agent_id") { me = agent(id: aid.trimmed) }',
     'if let aid = args.str("agent_id") { me = findAgent(aid, project: nil) }'),
    ("[sec] H2 token file world-readable", "Auth.swift",
     "attributes: [.posixPermissions: 0o600])", "attributes: [.posixPermissions: 0o644])"),
    ("[sec] M2 anonymous send_message", "MCPServer.swift",
     "// Anonymous senders would be shown as the human (M2): only an identified agent may send.\n            guard let me else",
     "// Anonymous senders would be shown as the human (M2): only an identified agent may send.\n            guard let _ = Optional(1) else"),
    ("[sec] M2 peer text not neutralized", "Core.swift",
     's.replacingOccurrences(of: "[AgentBoard]", with: "(AgentBoard)", options: .caseInsensitive)',
     's.replacingOccurrences(of: "[AgentBoard]", with: "[AgentBoard]", options: .caseInsensitive)'),
    ("[sec] M2 peer fence can be closed", "Core.swift",
     '.replacingOccurrences(of: ">>>", with: "›››")', '.replacingOccurrences(of: ">>>>>>", with: "›››")'),
    ("[sec] M2 any name accepted", "MCPServer.swift",
     "        let n = raw.trimmed\n", "        let n = raw.trimmed\n        if !n.isEmpty { return n }\n"),
    ("[sec] L1 prompt file kept", "Workspaces.swift",
     ' && rm -f \\(shq(promptFile)) && ', ' && '),
    ("[sec] L2 links stay clickable", "Views/Components.swift",
     "                piece.link = nil\n", ""),
    ("[sec] L3 no body limit", "HTTPServer.swift",
     "if Self.declaredTooLarge(buf, limit: self.maxRequestBytes) || buf.count > self.maxRequestBytes {", "if false {"),
    ("[sec] L3 no connection cap", "HTTPServer.swift",
     "if openConnections >= maxConnections {", "if false {"),
    ("[sec] L3 no read timeout", "HTTPServer.swift",
     "if idle { c.cancel() }", "_ = idle"),
    ("Removed projects still tracked", "Core.swift",
     'db.query("SELECT * FROM projects WHERE archived_at IS NULL ORDER BY name COLLATE NOCASE")',
     'db.query("SELECT * FROM projects ORDER BY name COLLATE NOCASE")'),
    ("Re-adding a removed project creates a new one", "Core.swift",
     'if let old = db.query("SELECT * FROM projects WHERE path=? AND archived_at IS NOT NULL", [root])',
     'if let old = db.query("SELECT * FROM projects WHERE path=? AND 0", [root])'),
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
