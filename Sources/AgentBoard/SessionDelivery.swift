import AppKit
import Foundation

enum DeliveryMode: String, CaseIterable, Identifiable {
    case auto, terminal, inbox, resume
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Авто"
        case .terminal: return "Напечатать в терминал агента"
        case .inbox: return "В контекст при следующем шаге"
        case .resume: return "Продолжить сессию в фоне"
        }
    }
    var help: String {
        switch self {
        case .auto: return "Работает → в контекст на следующем шаге; ждёт ввода → печатаем в его терминал; иначе — в очередь."
        case .terminal: return "Текст вводится во вкладку Terminal.app / iTerm2 / tmux, где запущен агент, и отправляется Enter — как будто вы написали сам."
        case .inbox: return "Агент увидит комментарий после ближайшего действия, при следующем запросе или в конце хода (и продолжит работу)."
        case .resume: return "Новый запуск той же сессии без терминала (claude -p --resume / codex exec resume). Для закрытых сессий. Не используйте, пока сессия открыта в терминале."
        }
    }
}

/// Sends a human comment into a specific agent session so the agent continues with it.
enum SessionDelivery {
    static let prefix = "[Комментарий из AgentBoard] "

    /// Runs off the main thread; completion on main with a human-readable result.
    static func deliver(agentId: String, text: String, mode: DeliveryMode, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(agentId: agentId, text: text, mode: mode)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run(agentId: String, text: String, mode: DeliveryMode) -> String {
        let core = Core.shared
        guard let a = core.q.sync(execute: { core.agent(id: agentId) }) else { return "Агент не найден" }
        let st = a.displayStatus(staleMinutes: AppSettings.staleMinutes)
        let log: (String, String) -> Void = { kind, how in
            core.q.async {
                core.addEvent(project: a.projectId, agent: nil, kind: "message",
                              title: "Вы → \(a.name) (\(how)): \(text.oneLine.trunc(160))", detail: text)
                core.changed()
                _ = kind
            }
        }
        func toInbox() -> String {
            core.q.sync { _ = core.sendMessage(project: a.projectId, to: a.id, from: nil, text: text) }
            return st == .working
                ? "Комментарий попадёт к \(a.name) на ближайшем шаге — агент продолжит с его учётом."
                : "Комментарий в очереди: \(a.name) получит его при следующем действии или запросе."
        }

        switch mode {
        case .inbox:
            return toInbox()
        case .terminal:
            if let how = typeIntoTerminal(a, text) { log("message", how); return "Отправлено в терминал \(a.name) (\(how))." }
            return "Не нашёл терминал \(a.name). Поддерживаются Terminal.app, iTerm2 и tmux; для Claude Code нужен хотя бы один запрос после подключения хуков. Попробуйте «В контекст» или «Продолжить в фоне»."
        case .resume:
            return resume(a, text)
        case .auto:
            if st == .working { return toInbox() }
            if st == .waiting || st == .idle || st == .stale, let how = typeIntoTerminal(a, text) {
                log("message", how)
                return "Агент \(a.name) ждал ввода — комментарий напечатан в его терминал (\(how)), он продолжает работу."
            }
            return toInbox() + (st == .ended ? " Сессия закрыта — чтобы продолжить её сейчас, выберите «Продолжить сессию в фоне»." : "")
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
        guard let exe, !a.sessionId.hasPrefix("mcp-") else { return "Для этого агента фоновое продолжение недоступно" }
        core.q.async {
            core.addEvent(project: a.projectId, agent: a.id, kind: "message",
                          title: "Вы → \(a.name) (фоновое продолжение): \(text.oneLine.trunc(160))", detail: text)
            core.setAgent(a.id, ["status": "working", "last_action": "продолжает в фоне по вашему комментарию"])
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
                    core.addEvent(project: a.projectId, agent: a.id, kind: "waiting", title: "Не удалось продолжить \(a.name): \(error.localizedDescription)")
                    core.changed()
                }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmed
            core.q.async {
                core.addEvent(project: a.projectId, agent: a.id, kind: "turn_done",
                              title: "\(a.name) закончил фоновое продолжение" + (p.terminationStatus == 0 ? "" : " (код \(p.terminationStatus))"),
                              detail: output.trunc(4000))
                core.setAgent(a.id, ["status": "idle", "last_action": "фоновое продолжение завершено"])
                core.changed()
                core.notify?("\(a.name) закончил работу по комментарию", output.oneLine.trunc(200))
            }
        }
        return "Запущено фоновое продолжение сессии \(a.name). Действия и результат появятся в ленте."
    }
}
