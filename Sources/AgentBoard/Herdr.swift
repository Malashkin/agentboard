import Foundation

/// Delivery through herdr (https://herdr.dev), a terminal workspace manager for coding agents.
///
/// Why this exists at all: herdr starts every agent in a pseudo-terminal it creates itself, so no
/// Terminal.app tab, iTerm2 session or tmux pane owns that terminal. Typing into the agent's input
/// is only possible for the process holding the pty master — and that process is herdr. Without
/// this path AgentBoard can see such an agent, name it and queue messages for it, but can never
/// wake it: a comment to an agent that is waiting for input sits in the queue until the human
/// types in the terminal by hand, which looks exactly like "sending from the app doesn't work".
///
/// Herdr is detected, not configured: people either use it or they don't, and the same build has
/// to serve both. With no `herdr` binary on the machine nothing is asked and the older paths
/// (tmux, iTerm2, Terminal.app) behave exactly as before.
enum Herdr {
    /// A session herdr knows about. The pane id is the only target its CLI accepts.
    struct Pane: Equatable {
        let id: String
        /// What herdr sees: idle · working · blocked · done · unknown.
        let status: String
    }

    static var binary: String? { Shell.which("herdr") }

    static var isInstalled: Bool { binary != nil }

    /// The pane of a session, or nil if herdr doesn't manage it.
    static func pane(sessionId: String, tool: String) -> Pane? {
        guard !sessionId.isEmpty, let bin = binary else { return nil }
        let r = Shell.run(bin, ["agent", "list"], timeout: 10)
        return parsePane(json: r.out, sessionId: sessionId, tool: tool)
    }

    /// Picks the session's pane out of `herdr agent list`.
    ///
    /// Matching is by session id, which herdr reports as the agent's own
    /// (`agent_session.value`) — the very id AgentBoard stores. That makes the lookup exact:
    /// eight sessions open on one repository stay distinguishable, which matching by working
    /// directory cannot do.
    ///
    /// Split out from `pane(sessionId:tool:)` so it can be checked without herdr installed.
    static func parsePane(json: String, sessionId: String, tool: String) -> Pane? {
        guard !sessionId.isEmpty,
              let root = parseJSON(Data(json.utf8)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return nil }

        for a in agents {
            guard let session = a["agent_session"] as? [String: Any],
                  let value = session["value"] as? String, value == sessionId else { continue }
            // A session id belongs to one tool; a mismatch means we are looking at someone else's.
            if let t = a["agent"] as? String, !t.isEmpty, t != tool { continue }
            guard let pane = a["pane_id"] as? String, !pane.isEmpty else { return nil }
            return Pane(id: pane, status: (a["agent_status"] as? String) ?? "unknown")
        }
        return nil
    }

    /// Hands the text to the agent as a prompt, as if it had been typed into its terminal.
    static func prompt(pane: String, text: String) -> Bool {
        guard let bin = binary, !pane.isEmpty, !text.isEmpty else { return false }
        let r = Shell.run(bin, ["agent", "prompt", pane, text], timeout: 20)
        return succeeded(json: r.out, exitCode: r.code)
    }

    /// Makes the pane the visible one in herdr.
    static func focus(pane: String) -> Bool {
        guard let bin = binary, !pane.isEmpty else { return false }
        let r = Shell.run(bin, ["agent", "focus", pane], timeout: 10)
        return succeeded(json: r.out, exitCode: r.code)
    }

    /// The terminal the herdr client is attached in (so its window can be raised), if one is.
    static func clientTTY() -> String? {
        let ps = Shell.run("/bin/ps", ["-axo", "tty=,comm="], timeout: 5).out
        return clientTTY(psOutput: ps)
    }

    static func clientTTY(psOutput: String) -> String? {
        for l in psOutput.split(separator: "\n") {
            let f = l.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard f.count == 2, f[0].hasPrefix("ttys"),
                  URL(fileURLWithPath: f[1].trimmingCharacters(in: .whitespaces)).lastPathComponent == "herdr" else { continue }
            return "/dev/" + f[0]
        }
        return nil
    }

    /// Whether a herdr command worked.
    ///
    /// Its CLI reports failures as `{"error":{…}}` and still exits 0, so the exit status alone
    /// would read every refusal as success. The status is only consulted when the output isn't
    /// JSON at all (the binary missing, a crash).
    static func succeeded(json: String, exitCode: Int32) -> Bool {
        guard let root = parseJSON(Data(json.utf8)) as? [String: Any] else { return exitCode == 0 }
        return root["error"] == nil
    }

    /// Herdr tracks an agent in that pane, so a prompt will reach it rather than a bare shell.
    /// `auto`: the app decided to type on its own (Auto mode) because it believes the agent is at its
    /// prompt. Herdr sees the terminal itself, so when it says the agent is busy that wins — typing
    /// mid-turn would interrupt the work; the message goes to the inbox instead.
    static func canPrompt(_ p: Pane, auto: Bool = false) -> Bool {
        if p.status == "unknown" { return false }
        return !auto || ["idle", "blocked", "done"].contains(p.status)
    }
}
