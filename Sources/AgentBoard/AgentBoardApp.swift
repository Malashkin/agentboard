import AppKit
import SwiftUI

@main
struct AgentBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared

    init() {
        // CLI mode: `AgentBoard --install-claude [--install-codex]` runs the same installers as the "Подключения" screen.
        let args = CommandLine.arguments
        if args.contains("--install-claude") || args.contains("--install-codex") || args.contains("--uninstall-claude") {
            Pref.registerDefaults()
            Integrations.writeBridge()
            func step(_ name: String, _ work: () throws -> Void) {
                do { try work(); print("✓ \(name)") } catch { print("✗ \(name): \(error.localizedDescription)") }
            }
            if args.contains("--uninstall-claude") {
                step("Claude Code hooks removed") { try Integrations.uninstallClaudeHooks() }
                step("Claude Code MCP removed") { Integrations.uninstallClaudeMCP() }
            }
            if args.contains("--install-claude") {
                step("Claude Code hooks → ~/.claude/settings.json") { try Integrations.installClaudeHooks() }
                step("Claude Code MCP agentboard → \(Integrations.mcpURL)") { try Integrations.installClaudeMCP() }
            }
            if args.contains("--install-codex") {
                step("Codex → ~/.codex/config.toml") { try Integrations.installCodex() }
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("AgentBoard", id: "main") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: HTTPServer?
    private var summaryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        Pref.registerDefaults()
        Notifier.shared.setup()

        let store = Store.shared
        let core = Core.shared
        do {
            try core.q.sync { try core.setup() }
        } catch {
            store.serverError = "База данных: \(error.localizedDescription)"
            return
        }
        core.onChange = { store.scheduleReload() }
        core.notify = { title, body in Notifier.shared.post(title, body) }
        store.reload()

        Integrations.writeBridge()
        startServer()

        GitMonitor.shared.onUpdate = { snap in store.git = snap }
        GitMonitor.shared.start()
        CodexWatcher.shared.start()

        // Debug aid: AGENTBOARD_SNAPSHOT=/path.png saves an image of the main window (no screen-recording permission needed).
        if let shot = ProcessInfo.processInfo.environment["AGENTBOARD_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
                      let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
            }
        }

        summaryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Self.maybeAutoSummary() }
    }

    func startServer() {
        server?.stop()
        let port = AppSettings.port
        let s = HTTPServer(port: port) { req, reply in
            Core.shared.q.async { Core.shared.route(req, reply) }
        }
        s.onState = { running, err in
            DispatchQueue.main.async {
                Store.shared.serverRunning = running
                if let err { Store.shared.serverError = err }
                else if running { Store.shared.serverError = nil }
            }
        }
        do { try s.start() } catch {
            Store.shared.serverError = "Сервер на порту \(port): \(error.localizedDescription)"
        }
        server = s
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Store.shared.requestOpenMain() }
        return true
    }

    /// Writes the evening summary once a day after the configured time, if anything happened.
    static func maybeAutoSummary() {
        guard AppSettings.autoSummary else { return }
        let cal = Calendar.current
        let nowDate = Date()
        guard let due = cal.date(bySettingHour: AppSettings.summaryHour, minute: AppSettings.summaryMinute, second: 0, of: nowDate),
              nowDate >= due else { return }
        let key = Fmt.dayKey.string(from: nowDate)
        let store = Store.shared
        if store.summaries.contains(where: { $0.day == key }) || store.generatingDays.contains(key) { return }
        let start = cal.startOfDay(for: nowDate).timeIntervalSince1970
        guard store.events.contains(where: { $0.createdAt >= start }) else { return }
        store.generateSummary(day: nowDate)
    }
}
