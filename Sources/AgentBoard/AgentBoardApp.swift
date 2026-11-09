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

        GitMonitor.shared.onUpdate = { snap in if store.git != snap { ThemeStore.animate { store.git = snap } } }
        GitMonitor.shared.start()
        CodexWatcher.shared.start()
        SessionLiveness.shared.start()
        // Keep each project's git hooks current (pre-commit guard added in newer versions, moved folders).
        DispatchQueue.global(qos: .utility).async {
            for p in core.q.sync(execute: { core.allProjects() }) { try? Integrations.installGitHook(p) }
        }

        // Debug aid: AGENTBOARD_SNAPSHOT=/path.png saves an image of the main window (no screen-recording permission needed).
        if let shot = ProcessInfo.processInfo.environment["AGENTBOARD_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["AGENTBOARD_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
                      let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
            }
        }

        // Catch up on sessions that ran while the app was closed (each session is imported once).
        if !Self.isTesting { for p in core.q.sync(execute: { core.allProjects() }) { store.importHistory(p) } }

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

    /// Evening summary: written at the configured time while the app runs (within an hour of it);
    /// if the app was closed then, yesterday's summary is written on the next launch.
    static func maybeAutoSummary() {
        guard AppSettings.autoSummary, !isTesting else { return }
        let cal = Calendar.current
        let nowDate = Date()
        let store = Store.shared
        func hasSummary(_ d: Date) -> Bool {
            let k = Fmt.dayKey.string(from: d)
            return store.summaries.contains { $0.day == k } || store.generatingDays.contains(k)
        }
        func hadActivity(_ d: Date) -> Bool {
            let (from, to) = SummaryService.dayRange(d)
            return Core.shared.q.sync {
                !Core.shared.db.query("SELECT id FROM events WHERE created_at >= ? AND created_at < ? LIMIT 1", [from, to]).isEmpty
            }
        }
        if let due = cal.date(bySettingHour: AppSettings.summaryHour, minute: AppSettings.summaryMinute, second: 0, of: nowDate),
           nowDate >= due, nowDate < due.addingTimeInterval(3600), !hasSummary(nowDate), hadActivity(nowDate) {
            store.generateSummary(day: nowDate)
            return
        }
        if let y = cal.date(byAdding: .day, value: -1, to: nowDate), !hasSummary(y), hadActivity(y) {
            store.generateSummary(day: y)
        }
    }

    /// Isolated test runs never call the real `claude`.
    static var isTesting: Bool { ProcessInfo.processInfo.environment["AGENTBOARD_DATA_DIR"] != nil }
}
