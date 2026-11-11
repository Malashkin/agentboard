import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Getting to an agent fast without leaving what you're doing: bring its terminal to the front,
/// jump through the agents that need you, answer from a small panel. All of it works on the
/// terminals the human already uses — AgentBoard never owns the session.
enum TerminalFocus {
    /// Brings the agent's terminal tab (Terminal.app, iTerm2, a tmux pane inside either) to the front.
    /// Returns where it went, or a human-readable reason it couldn't.
    static func focus(_ a: Agent) -> Result<String, FocusError> {
        var how = ""
        var herdrTTY: String?
        if let pane = Herdr.pane(sessionId: a.sessionId, tool: a.tool), pane.status != "unknown" {
            // Herdr owns the agent's pty: switch herdr to that pane, then raise the terminal herdr itself runs in.
            guard Herdr.focus(pane: pane.id) else { return .failure(.init("herdr couldn't switch to \(a.name)'s pane \(pane.id)")) }
            how = "herdr \(pane.id) in "
            herdrTTY = Herdr.clientTTY()
            if herdrTTY == nil { return .success("herdr \(pane.id)") }
        }
        guard var tty = herdrTTY ?? SessionDelivery.terminalTTY(a) else {
            return .failure(.init("Couldn't find \(a.name)'s terminal. It may be closed, or Claude Code hasn't sent a prompt since the hooks were installed."))
        }
        if let pane = SessionDelivery.tmuxPane(tty: tty), let tmux = Shell.which("tmux") {
            _ = Shell.run(tmux, ["select-window", "-t", pane], timeout: 5)
            _ = Shell.run(tmux, ["select-pane", "-t", pane], timeout: 5)
            how += "tmux \(pane) in "
            // The window to raise is the terminal showing the tmux client, not the pane's own pty.
            let clients = Shell.run(tmux, ["list-clients", "-F", "#{client_tty}"], timeout: 5).out
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("/dev/") }
            if let c = clients.first { tty = c } else { return .success("tmux \(pane) (no attached client to raise)") }
        }
        var denied: [String] = []
        if SessionDelivery.isRunning("com.googlecode.iterm2") {
            let r = SessionDelivery.osa(itermScript(tty: tty))
            if r == "ok" { return .success(how + "iTerm2") }
            if SessionDelivery.isAutomationDenied(r) { denied.append("iTerm2") }
        }
        if SessionDelivery.isRunning("com.apple.Terminal") {
            let r = SessionDelivery.osa(terminalScript(tty: tty))
            if r == "ok" { return .success(how + "Terminal") }
            if SessionDelivery.isAutomationDenied(r) { denied.append("Terminal") }
        }
        if !denied.isEmpty {
            return .failure(.init("macOS doesn't let AgentBoard control \(denied.joined(separator: " and ")). Allow it in System Settings → Privacy & Security → Automation → AgentBoard, then try again."))
        }
        return .failure(.init("\(a.name)'s terminal (\(tty)) isn't a Terminal.app or iTerm2 tab AgentBoard can raise"))
    }

    struct FocusError: Error { let message: String; init(_ m: String) { message = m } }

    static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  select w
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "no"
        """
    }

    static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "no"
        """
    }
}

/// Who needs the human, in the order to visit them.
enum Attention {
    /// Agents with an open request or waiting for a reply come first (longest wait first), then stuck
    /// ones, then those sitting idle at their prompt (most recent first). Working and finished agents
    /// don't need you.
    static func queue(_ agents: [Agent], status: (Agent) -> AgentStatus, requested: Set<String>) -> [Agent] {
        func rank(_ a: Agent) -> Int? {
            if requested.contains(a.id) { return 0 }
            switch status(a) {
            case .waiting: return 0
            case .stuck: return 1
            case .idle: return 2
            default: return nil
            }
        }
        return agents.compactMap { a in rank(a).map { (a, $0) } }
            .sorted { l, r in
                if l.1 != r.1 { return l.1 < r.1 }
                return l.1 == 2 ? l.0.lastSeen > r.0.lastSeen : l.0.lastSeen < r.0.lastSeen
            }
            .map(\.0)
    }

    /// The next one after `last` (wrapping), so repeated presses walk the whole queue.
    static func next(after last: String?, in queue: [Agent]) -> Agent? {
        guard !queue.isEmpty else { return nil }
        guard let last, let i = queue.firstIndex(where: { $0.id == last }) else { return queue.first }
        return queue[(i + 1) % queue.count]
    }
}

/// System-wide shortcuts through Carbon's RegisterEventHotKey: no Accessibility permission needed.
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4142_4F44), id: id)   // 'ABOD'
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
    }

    /// ⌥⌘J — bring the next agent that needs you to the front. ⌥⌘K — the quick-answer panel.
    static func apply() {
        shared.unregisterAll()
        guard AppSettings.globalHotkeys else { return }
        let mods = optionKey | cmdKey
        shared.register(id: 1, keyCode: kVK_ANSI_J, modifiers: mods) { Store.shared.jumpToNextAgent() }
        shared.register(id: 2, keyCode: kVK_ANSI_K, modifiers: mods) { QuickPanel.shared.toggle() }
    }
}

/// A small floating window: every open request and every agent that waits for you, with a reply
/// field and a button to its terminal. Opened with ⌥⌘K from anywhere, closed with Esc.
final class QuickPanel: NSObject, NSWindowDelegate {
    static let shared = QuickPanel()
    private var panel: NSPanel?

    func toggle() {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        show()
    }

    func show() {
        let p = panel ?? make()
        panel = p
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Needs you"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = NSHostingView(rootView: QuickPanelView().environmentObject(Store.shared).hoverButtons())
        return p
    }
}

struct QuickPanelView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let queue = store.attentionQueue
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Needs you").font(.title3.bold())
                    Spacer()
                    Text("⌥⌘J next agent · Esc close").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.pending) { p in
                    ApprovalRow(item: p, compact: true)
                    Divider()
                }
                if queue.isEmpty && store.pending.isEmpty {
                    Text("Nobody is waiting for you. Agents that are working don't need anything.")
                        .foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(queue) { a in QuickAgentRow(agent: a) }
            }
            .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 28)
        }
        .frame(minWidth: 460, minHeight: 240)
        .tint(ThemeStore.shared.accent)
        .preferredColorScheme(ThemeStore.shared.colorScheme)
        .onExitCommand { QuickPanel.shared.close() }
    }
}

struct QuickAgentRow: View {
    @EnvironmentObject var store: Store
    let agent: Agent
    @State private var reply = ""
    @State private var result: String?

    var body: some View {
        let st = store.status(agent)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: st.icon).foregroundStyle(st.color)
                Text(agent.name).font(.headline)
                Text(store.project(agent.projectId)?.name ?? "").foregroundStyle(.secondary)
                Spacer()
                Text(st.label).font(.caption).foregroundStyle(st.color)
                Button { store.focusTerminal(agent) { result = $0 } } label: { Label("Terminal", systemImage: "terminal") }
                    .help("Bring its terminal to the front")
            }
            Text(!agent.narrative.isEmpty ? agent.narrative : agent.lastAction)
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                TextField(st == .waiting ? "Reply to \(agent.name)…" : "Next instruction for \(agent.name)…", text: $reply)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }.disabled(reply.trimmed.isEmpty)
            }
            if let result { Text(result).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(st.color.opacity(0.07)))
    }

    func send() {
        let text = reply.trimmed
        guard !text.isEmpty else { return }
        reply = ""
        SessionDelivery.deliver(agentId: agent.id, text: text, mode: .auto) { result = $0 }
    }
}
