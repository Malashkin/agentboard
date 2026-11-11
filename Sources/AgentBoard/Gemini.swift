import Foundation

/// Gemini CLI support. Its hooks (settings.json → "hooks", v0.26+) carry the same kind of JSON as Claude Code's,
/// under other names: this translates an event into Claude Code's shape, runs it through the same handler
/// (`agentTool` = "gemini"), and translates the answer back. Everything else — cards, feed, reservations,
/// messages, decisions — is shared.
enum GeminiHooks {
    /// Gemini CLI event → Claude Code event.
    static let events: [String: String] = [
        "SessionStart": "SessionStart",
        "BeforeAgent": "UserPromptSubmit",
        "BeforeTool": "PreToolUse",
        "AfterTool": "PostToolUse",
        "AfterAgent": "Stop",
        "Notification": "Notification",
        "SessionEnd": "SessionEnd",
    ]

    /// Gemini CLI built-in tool → the Claude Code tool AgentBoard understands (same meaning).
    static let tools: [String: String] = [
        "run_shell_command": "Bash",
        "write_file": "Write",
        "replace": "Edit",
        "read_file": "Read",
        "read_many_files": "Read",
        "glob": "Glob",
        "search_file_content": "Grep",
        "grep_search": "Grep",
        "list_directory": "LS",
        "web_fetch": "WebFetch",
        "google_web_search": "WebSearch",
        "save_memory": "Memory",
    ]

    /// A Gemini CLI hook payload in Claude Code's shape, or nil for an event AgentBoard doesn't use.
    static func toClaude(_ j: JSON) -> JSON? {
        guard let ev = j.str("hook_event_name"), var mapped = events[ev] else { return nil }
        var out = j
        if let t = j.str("tool_name") {
            out["tool_name"] = tools[t] ?? (t.hasPrefix("mcp_") ? "mcp__" + t.dropFirst(4) : t)
        }
        if var input = j["tool_input"] as? JSON {
            // read_file names its path `absolute_path` in some versions; the rest use file_path.
            if input["file_path"] == nil, let p = input.str("absolute_path") ?? input.str("path") { input["file_path"] = p }
            if input["pattern"] == nil, let p = input.str("query") { input["pattern"] = p }
            out["tool_input"] = input
        }
        if ev == "AfterTool", let resp = j["tool_response"] as? JSON {
            let err = resp["error"]
            if let e = err, !(e is NSNull), !"\(e)".isEmpty {
                mapped = "PostToolUseFailure"
                out["error"] = (e as? String) ?? (e as? JSON)?.str("message") ?? "\(e)"
            } else {
                out["tool_response"] = resp.str("returnDisplay") ?? resp.str("llmContent") ?? ""
            }
        }
        if ev == "AfterAgent" { out["last_assistant_message"] = j.s("prompt_response") }
        if ev == "Notification", out["message"] == nil {
            out["message"] = j.str("notification_type") == "ToolPermission" ? "Gemini CLI needs your permission" : "Gemini CLI is waiting"
        }
        out["hook_event_name"] = mapped
        return out
    }

    /// AgentBoard's answer in Claude Code's shape → what Gemini CLI reads from stdout.
    /// Context is the same (`hookSpecificOutput.additionalContext`); a refusal is a top-level `decision: deny`
    /// (Gemini sends `reason` to the model); a blocked Stop ("keep going, you have messages") is AfterAgent's
    /// deny, which makes Gemini continue with the reason.
    static func fromClaude(event: String, _ data: Data?) -> Data? {
        guard let data, let o = parseJSON(data) as? JSON else { return nil }
        var out: JSON = [:]
        if let h = o["hookSpecificOutput"] as? JSON {
            if let c = h.str("additionalContext"), !c.isEmpty, event != "BeforeTool" || h.str("permissionDecision") != "deny" {
                out["hookSpecificOutput"] = ["additionalContext": c]
            }
            switch h.str("permissionDecision") {
            case "deny":
                out["decision"] = "deny"
                out["reason"] = h.str("permissionDecisionReason") ?? h.str("additionalContext") ?? "Refused by AgentBoard"
            case "allow":
                out["decision"] = "allow"
            default: break
            }
        }
        if o.str("decision") == "block" {
            out["decision"] = "deny"
            out["reason"] = o.s("reason")
        }
        return out.isEmpty ? nil : jsonData(out)
    }
}
