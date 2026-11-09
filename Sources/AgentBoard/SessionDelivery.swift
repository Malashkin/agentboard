import AppKit
import Foundation

enum DeliveryMode: String, CaseIterable, Identifiable {
    case auto, terminal, inbox, resume
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .terminal: return "Type into the agent's terminal"
        case .inbox: return "Into context at the next step"
        case .resume: return "Resume the session in the background"
        }
    }
    var help: String {
        switch self {
        case .auto: return "Working → into context at the next step; waiting for input → typed into its terminal; otherwise — queued."
        case .terminal: return "The text is typed into the Terminal.app / iTerm2 / tmux tab where the agent runs and sent with Enter — as if you typed it yourself."
        case .inbox: return "The agent sees the comment after its next action, on the next prompt, or at the end of the turn (and keeps working)."
        case .resume: return "A new run of the same session without a terminal (claude -p --resume / codex exec resume). For closed sessions. Don't use it while the session is open in a terminal."
        }
    }
}

/// Sends a human comment into a specific agent session so the agent continues with it.
enum SessionDelivery {
    static let prefix = "[Comment from AgentBoard] "

    /// Runs off the main thread; completion on main with a human-readable result.
    static func deliver(agentId: String, text: String, mode: DeliveryMode, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(agentId: agentId, text: text, mode: mode)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func run(agentId: String, text: String, mode: DeliveryMode) -> String {
        let core = Core.shared
        guard let a = core.q.sync(execute: { core.agent(id: agentId) }) else { return "Agent not found" }
        let st = a.displayStatus(staleMinutes: AppSettings.staleMinutes)
        let log: (String, String) -> Void = { kind, how in
            core.q.async {
                core.addEvent(project: a.projectId, agent: nil, kind: "message",
                              title: "You → \(a.name) (\(how)): \(text.oneLine.trunc(160))", detail: text)
                core.changed()
                _ = kind
            }
        }
        func toInbox() -> String {
            core.q.sync { _ = core.sendMessage(project: a.projectId, to: a.id, from: nil, text: text) }
            return st == .working
                ? "\(a.name) will get the comment at its next step and continue with it in mind."
                : "Comment queued: \(a.name) will get it on its next action or prompt."
        }

        switch mode {
        case .inbox:
            return toInbox()
        case .terminal:
            if let how = typeIntoTerminal(a, text) { log("message", how); return "Sent to \(a.name)'s terminal (\(how))." }
            return "Couldn't find \(a.name)'s terminal. Terminal.app, iTerm2 and tmux are supported; Claude Code needs at least one prompt after the hooks are installed. Try \"Into context\" or \"Resume in the background\"."
        case .resume:
            return resume(a, text)
        case .auto:
            if st == .working { return toInbox() }
            if st == .waiting || st == .idle || st == .stale, let how = typeIntoTerminal(a, text) {
                log("message", how)
                return "\(a.name) was waiting for input — the comment was typed into its terminal (\(how)), and it is continuing."
            }
            return toInbox() + (st == .ended ? " The session is closed — to continue it now, choose \"Resume the session in the background\"." : "")
        }
    }

    // MARK: Terminal

    /// Returns a description of where the text was typed, or nil.
    static func typeIntoTerminal(_ a: Agent, _ text: String) -> String? {
        let line = (prefix + text).oneLine
        var tty = a.tty
        if tty.isEmpty || a.tool == "codex" { tty = findTTY(tool: a.tool, cwd: a.cwd) ?? tty }
        guard tty.hasPrefix("/dev/ttys") else { return nil }

        if let pane = tmuxPane(tty: tty) {
            let tmux = Shell.which("tmux") ?? "tmux"
            let r1 = Shell.run(tmux, ["send-keys", "-t", pane, "-l", line])
            Thread.sleep(forTimeInterval: 0.15)
            let r2 = Shell.run(tmux, ["send-keys", "-t", pane, "Enter"])
            if r1.ok && r2.ok { return "tmux \(pane)" }
        }
        let esc = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if isRunning("com.googlecode.iterm2") {
            let script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      tell s to write text "\(esc)" newline no
                      delay 0.15
                      tell s to write text ""
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "no"
            """
            if osa(script) == "ok" { return "iTerm2" }
        }
        if isRunning("com.apple.Terminal") {
            let script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    do script "\(esc)" in t
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "no"
            """
            if osa(script) == "ok" { return "Terminal" }
        }
        return nil
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private static func osa(_ script: String) -> String {
        Shell.run("/usr/bin/osascript", ["-e", script], timeout: 15).line
    }

    private static func tmuxPane(tty: String) -> String? {
        guard let tmux = Shell.which("tmux") else { return nil }
        let r = Shell.run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"], timeout: 5)
        guard r.ok else { return nil }
        for l in r.out.split(separator: "\n") {
            let f = l.split(separator: " ")
            if f.count == 2, String(f[0]) == tty { return String(f[1]) }
        }
        return nil
    }

    /// Finds the terminal of a running agent process by its working directory.
    static func findTTY(tool: String, cwd: String) -> String? {
        let ps = Shell.run("/bin/ps", ["-axo", "pid=,tty=,comm="], timeout: 5)
        for l in ps.out.split(separator: "\n") {
            let f = l.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard f.count == 3, f[1].hasPrefix("ttys") else { continue }
            let name = URL(fileURLWithPath: f[2]).lastPathComponent
            guard name == tool || name.hasPrefix(tool) else { continue }
            let lsof = Shell.run("/usr/sbin/lsof", ["-a", "-p", f[0], "-d", "cwd", "-Fn"], timeout: 5)
            let dir = lsof.out.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? ""
            if dir == cwd { return "/dev/" + f[1] }
        }
        return nil
    }

    // MARK: Headless resume

    private static func resume(_ a: Agent, _ text: String) -> String {
        let core = Core.shared
        let message = prefix + text
        var exe: String?
        var args: [String] = []
        if a.tool == "claude" {
            exe = Shell.which("claude")
            args = ["-p", "--resume", a.sessionId, "--permission-mode", "acceptEdits", message]
        } else if a.tool == "codex" {
            exe = Shell.which("codex")
            args = ["exec", "resume", a.sessionId, message]
        }
        guard let exe, !a.sessionId.hasPrefix("mcp-") else { return "Background resume isn't available for this agent" }
        core.q.async {
            core.addEvent(project: a.projectId, agent: a.id, kind: "message",
                          title: "You → \(a.name) (background resume): \(text.oneLine.trunc(160))", detail: text)
            core.setAgent(a.id, ["status": "working", "last_action": "continuing in the background on your comment"])
            core.changed()
        }
        DispatchQueue.global().async {
            // Not marked internal: hooks of the resumed session report its actions to the board as usual.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: a.cwd)
            var env = Shell.cleanEnvironment
            env["PATH"] = Shell.extraPath + ":" + (env["PATH"] ?? "")
            env.removeValue(forKey: "AGENTBOARD_INTERNAL")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                core.q.async {
                    core.addEvent(project: a.projectId, agent: a.id, kind: "waiting", title: "Couldn't resume \(a.name): \(error.localizedDescription)")
                    core.changed()
                }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmed
            core.q.async {
                core.addEvent(project: a.projectId, agent: a.id, kind: "turn_done",
                              title: "\(a.name) finished the background resume" + (p.terminationStatus == 0 ? "" : " (exit code \(p.terminationStatus))"),
                              detail: output.trunc(4000))
                core.setAgent(a.id, ["status": "idle", "last_action": "background resume finished"])
                core.changed()
                core.notify?("\(a.name) finished working on your comment", output.oneLine.trunc(200))
            }
        }
        return "Started a background resume of \(a.name)'s session. Its actions and result will appear in the feed."
    }
}
