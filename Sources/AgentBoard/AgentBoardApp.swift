import AppKit
import SwiftUI

@main
struct AgentBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared

    init() {
        // CLI mode: `AgentBoard --install-claude [--install-codex]` runs the same installers as the "Connections" screen.
        let args = CommandLine.arguments
        if args.contains("--self-test") { exit(SelfTest.run()) }
        // `AgentBoard --discover`: read-only dry run of the "Suggested" scan (no database, no settings) with timing.
        if args.contains("--discover") {
            let t0 = Date()
            let found = ProjectDiscovery.scan(known: [], ignored: [])
            print(String(format: "%d suggestions in %.2f s, %d session files read, %.1f MB, %d folder lookups, %d git calls",
                         found.count, Date().timeIntervalSince(t0), ProjectDiscovery.stats.files,
                         Double(ProjectDiscovery.stats.bytes) / 1_048_576, ProjectDiscovery.stats.resolves, ProjectDiscovery.stats.gitCalls))
            for c in found.prefix(20) { print("  \(c.path)  (\(c.sessions) sessions, \(c.toolsLabel))") }
            exit(0)
        }
        if args.contains("--install-claude") || args.contains("--install-codex") || args.contains("--uninstall-claude")
            || args.contains("--install-gemini") || args.contains("--uninstall-gemini") {
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
            if args.contains("--install-gemini") {
                step("Gemini CLI hooks + MCP → ~/.gemini/settings.json") { try Integrations.installGemini() }
            }
            if args.contains("--uninstall-gemini") {
                step("Gemini CLI hooks + MCP removed") { try Integrations.uninstallGemini() }
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
            store.serverError = "Database: \(error.localizedDescription)"
            return
        }
        core.onChange = { store.scheduleReload() }
        core.notify = { title, body in Notifier.shared.post(title, body) }
        core.notifyRequest = { p in Notifier.shared.postRequest(p); Telegram.shared.request(p) }
        core.requestResolved = { id in Notifier.shared.remove(request: id); Telegram.shared.resolved(request: id) }
        core.notifyWaitingAgent = { a, title, body in
            Notifier.shared.postWaiting(agentId: a.id, title: title, body: body)
            Telegram.shared.waiting(a, title: title, body: body)
        }
        core.onPrompt = { a, prompt in TaskAutopilot.shared.onPrompt(a, prompt) }
        core.onSessionEnd = { a in TaskAutopilot.shared.onSessionEnd(a) }
        core.onUnknownFolder = { cwd in DispatchQueue.main.async { store.noteUnknownFolder(cwd) } }
        core.q.async { core.cleanupOldData() }
        store.reload()
        store.refreshSuggestions()

        Integrations.writeBridge()
        startServer()
        AppVisibility.start()
        // Not in a side instance: it would take the shortcuts from the real app.
        if !Integrations.isSideInstance { HotKeys.apply(); Telegram.shared.load() }
        DispatchQueue.global(qos: .utility).async {
            let missing = !Integrations.claudeHooksInstalled()
            DispatchQueue.main.async { store.hooksMissing = missing }
        }

        GitMonitor.shared.onUpdate = { snap in if store.git != snap { ThemeStore.animate { store.git = snap } } }
        GitMonitor.shared.start()
        CodexWatcher.shared.start()
        SessionLiveness.shared.start()
        Narrator.shared.start()
        AwayWatcher.shared.start()
        // Keep each project's git hooks current (pre-commit guard added in newer versions, moved folders).
        // Not in a side instance (test data / bridge dir): it would point the real Claude Code / Codex / repos at it.
        if !Integrations.isSideInstance { DispatchQueue.global(qos: .utility).async {
            for p in core.q.sync(execute: { core.allProjects() }) { try? Integrations.installGitHook(p) }
            // MCP registrations from older versions have no token (or an old port) → re-register.
            Integrations.refreshMCPRegistrations()
        } }

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
            Store.shared.serverError = "Server on port \(port): \(error.localizedDescription)"
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
