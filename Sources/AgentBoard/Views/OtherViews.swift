import AppKit
import SwiftUI

// MARK: - Summaries

struct SummariesView: View {
    @EnvironmentObject var store: Store
    @State private var selected: Int64?
    @State private var day = Date()

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                let key = Fmt.dayKey.string(from: day)
                Button {
                    store.generateSummary(day: day)
                } label: {
                    HStack {
                        if store.generatingDays.contains(key) { ProgressView().controlSize(.small) }
                        Text(store.generatingDays.contains(key) ? "Claude is writing the summary…" : "Generate summary")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.generatingDays.contains(key))
                Text(AppSettings.autoSummary ? "Automatically every day at \(String(format: "%02d:%02d", AppSettings.summaryHour, AppSettings.summaryMinute))" : "Auto-summary is off")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $selected) {
                    ForEach(store.summaries) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.day).font(.headline)
                            Text("\(Fmt.time(s.createdAt)) · \(s.source == "claude" ? "Claude" : s.source == "raw" ? "facts only" : "empty")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(s.id)
                        .contextMenu { Button("Delete", role: .destructive) { store.deleteSummary(s.id) } }
                    }
                }
                .listStyle(.inset)
            }
            .padding(12)
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

            Group {
                if let s = store.summaries.first(where: { $0.id == selected }) ?? (selected == nil ? store.summaries.first : nil) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Summary for \(s.day)").font(.headline)
                            Spacer()
                            Button { copyToPasteboard(s.markdown) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button {
                                let path = SummaryService.export(s) ?? SummaryService.exportPath(s)
                                revealInFinder(path)
                            } label: { Label("Show file", systemImage: "folder") }
                        }
                        .padding(12)
                        Divider()
                        ScrollView { MarkdownView(text: s.markdown).padding(24).frame(maxWidth: 860, alignment: .leading) }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.richtext").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No summaries yet").font(.headline)
                        Text("Pick a day and click “Generate summary”. Requires Claude Code (claude -p) to be installed.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Integrations

struct IntegrationsView: View {
    @EnvironmentObject var store: Store
    @State private var hooks = false
    @State private var mcp = false
    @State private var codex = false
    @State private var codexAvailable = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Integrations").font(.largeTitle.bold())
                Text("AgentBoard talks to your agents both ways: hooks tell the dashboard what each terminal is doing and deliver your messages to agents; the MCP server lets agents see the board and each other, and coordinate.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                IntegrationRow(
                    title: "Claude Code hooks",
                    detail: "Installed globally in ~/.claude/settings.json (with a backup). Active only in projects added to AgentBoard. Provides live status for every terminal, git commit interception, file conflict warnings, message delivery to agents, and collaboration rules at session start.",
                    installed: hooks, busy: busy,
                    install: { run { try Integrations.installClaudeHooks() } },
                    uninstall: { run { try Integrations.uninstallClaudeHooks() } })

                IntegrationRow(
                    title: "Claude Code agentboard MCP server",
                    detail: "claude mcp add --scope user agentboard \(Integrations.mcpURL). Tools: board, agent_activity, send_message, claim_task, create_task, update_task, set_focus, post_note, who_touches. Ask an agent to “check what Batman is doing” and it will call agent_activity.",
                    installed: mcp, busy: busy,
                    install: { run { try Integrations.installClaudeMCP() } },
                    uninstall: { run { Integrations.uninstallClaudeMCP() } })

                IntegrationRow(
                    title: "Codex",
                    detail: codexAvailable
                        ? "Adds the agentboard MCP server and notify to ~/.codex/config.toml (with a backup). Codex sees the board via MCP, and the dashboard sees every turn it takes. Also add the rules to AGENTS.md in project settings."
                        : "Codex isn’t installed on this Mac. You can connect it in advance; the config will be written to ~/.codex/config.toml.",
                    installed: codex, busy: busy,
                    install: { run { try Integrations.installCodex() } },
                    uninstall: nil)

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Technical details").font(.headline)
                        LabeledContent("Server") {
                            Text(store.serverRunning ? "running · http://127.0.0.1:\(AppSettings.port)" : "not running")
                                .foregroundStyle(store.serverRunning ? .green : .red)
                        }
                        LabeledContent("Bridge script") { Text(Integrations.hookPath).textSelection(.enabled) }
                        LabeledContent("Database") { Text(Core.shared.supportDir.path).textSelection(.enabled) }
                        Text("When the app is closed, hooks silently do nothing and don’t get in the agents’ way.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: refresh)
        .alert("Integrations", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func refresh() {
        DispatchQueue.global().async {
            let h = Integrations.claudeHooksInstalled(), m = Integrations.claudeMCPInstalled()
            let c = Integrations.codexInstalled(), ca = Integrations.codexAvailable
            DispatchQueue.main.async { hooks = h; mcp = m; codex = c; codexAvailable = ca }
        }
    }

    func run(_ work: @escaping () throws -> Void) {
        busy = true
        DispatchQueue.global().async {
            var err: String?
            do { try work() } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                busy = false
                message = err ?? "Done. Claude Code sessions that are already open will pick up the changes after a restart."
                refresh()
            }
        }
    }
}

struct IntegrationRow: View {
    let title: String
    let detail: String
    let installed: Bool
    let busy: Bool
    let install: () -> Void
    let uninstall: (() -> Void)?

    var body: some View {
        Card(tint: installed ? .green : .clear) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title2).foregroundStyle(installed ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Button(installed ? "Reinstall" : "Connect") { install() }
                        .buttonStyle(.borderedProminent).disabled(busy)
                    if installed, let uninstall { Button("Disconnect") { uninstall() }.disabled(busy) }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage(Pref.port) private var port = 7777
    @AppStorage(Pref.commitMode) private var commitMode = CommitMode.notify.rawValue
    @AppStorage(Pref.approvalTimeout) private var approvalTimeout = 300.0
    @AppStorage(Pref.injectContext) private var injectContext = true
    @AppStorage(Pref.conflictWarnings) private var conflictWarnings = true
    @AppStorage(Pref.notifyCommits) private var notifyCommits = true
    @AppStorage(Pref.notifyWaiting) private var notifyWaiting = true
    @AppStorage(Pref.notifyConflicts) private var notifyConflicts = true
    @AppStorage(Pref.autoSummary) private var autoSummary = true
    @AppStorage(Pref.summaryHour) private var summaryHour = 19
    @AppStorage(Pref.summaryMinute) private var summaryMinute = 0
    @AppStorage(Pref.exportDir) private var exportDir = NSHomeDirectory() + "/Documents/AgentBoard"
    @AppStorage(Pref.staleMinutes) private var staleMinutes = 30.0
    @AppStorage(Pref.summaryModel) private var summaryModel = ""
    @AppStorage(Pref.permissionsInApp) private var permissionsInApp = true
    @AppStorage(Pref.blockReservedEdits) private var blockReservedEdits = true
    @AppStorage(Pref.reservationMinutes) private var reservationMinutes = 30.0
    @AppStorage(Pref.stuckDetection) private var stuckDetection = true
    @AppStorage(Pref.stuckNudge) private var stuckNudge = true
    @AppStorage(Pref.terminalApp) private var terminalApp = "Terminal"
    @AppStorage(Pref.worktreeRoot) private var worktreeRoot = NSHomeDirectory() + "/.agentboard/worktrees"
    @AppStorage(Pref.narrator) private var narrator = true
    @AppStorage(Pref.autoTasks) private var autoTasks = true
    @AppStorage(Pref.awayDigest) private var awayDigest = true
    @AppStorage(Pref.awayMinutes) private var awayMinutes = 20.0
    @AppStorage(Pref.narratorMinutes) private var narratorMinutes = 2.0
    @AppStorage(Pref.narratorModel) private var narratorModel = "haiku"
    @AppStorage(Pref.scriptingAPI) private var scriptingAPI = false
    @AppStorage(Pref.globalHotkeys) private var globalHotkeys = true

    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                Toggle("Shortcuts from any app: ⌥⌘J next agent that needs you · ⌥⌘K answer panel", isOn: $globalHotkeys)
                    .onChange(of: globalHotkeys) { HotKeys.apply() }
                Stepper("Mark agent idle after \(Int(staleMinutes)) min of silence", value: $staleMinutes, in: 5...240, step: 5)
                TextField("Local server port", value: $port, format: .number.grouping(.never))
                Text("After changing the port, restart the app and reconnect MCP in Integrations.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow scripts to act for me (approve requests, create and launch tasks)", isOn: $scriptingAPI)
                Text("Local API: /api/decide, /api/tasks, /api/tasks/launch. Requests must carry the token from ~/.agentboard/token. Leave off unless you script AgentBoard — any program with the token could then approve agents' actions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("When an agent runs git commit", selection: $commitMode) {
                    ForEach(CommitMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Stepper("Wait \(Int(approvalTimeout)) s for a decision, then ask in the terminal",
                        value: $approvalTimeout, in: 30...1800, step: 30)
                    .disabled(commitMode != CommitMode.approve.rawValue)
                Text("“Ask for approval” pauses the agent before each commit until you click Allow in the window or the menu bar. Reinstall the hooks after changing the timeout.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Commits", systemImage: "checkmark.seal") }

            Form {
                Toggle("Tell agents what others are doing (on each new prompt, if anything changed)", isOn: $injectContext)
                Toggle("Warn agents when they edit files another agent is working on", isOn: $conflictWarnings)
                Section("Plain-language activity") {
                    Toggle("Show what the agent is doing on its card", isOn: $narrator)
                    Stepper("Update at most every \(narratorMinutes < 1 ? "30 s" : "\(Int(narratorMinutes)) min")",
                            value: $narratorMinutes, in: 0.5...10, step: 0.5).disabled(!narrator)
                    TextField("Model", text: $narratorModel).disabled(!narrator)
                    Text("Written by a fast model via `claude -p` (no tools, no saved session), only when the agent has new actions; finished turns and questions for you are shown immediately. Uses your Claude quota.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Tasks and digest") {
                    Toggle("Create board tasks from agents' requests automatically", isOn: $autoTasks)
                    Toggle("Show “While you were away” when you come back", isOn: $awayDigest)
                    Stepper("…after \(Int(awayMinutes)) min away", value: $awayMinutes, in: 5...240, step: 5).disabled(!awayDigest)
                }
                Section("File reservations") {
                    Toggle("Block edits to files reserved by another agent", isOn: $blockReservedEdits)
                    Stepper("Default reservation: \(Int(reservationMinutes)) min", value: $reservationMinutes, in: 5...240, step: 5)
                    Text("An agent’s commit that touches another agent’s reservation is blocked by the git pre-commit hook. Your own commits are never blocked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Permissions and questions") {
                    Toggle("Show agent permission requests, questions, and plans in the app", isOn: $permissionsInApp)
                    Text("Answer here or in the terminal as usual, whichever comes first. Requires reinstalled hooks (Integrations).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Stuck detection") {
                    Toggle("Detect when an agent is going in circles", isOn: $stuckDetection)
                    Toggle("Nudge the agent to stop and try a different approach", isOn: $stuckNudge).disabled(!stuckDetection)
                    Text("Signals: the same command fails 3 times in 20 minutes, 8 errors in a row, or the same action 5 times in the last 20.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Launching tasks") {
                    Picker("Terminal", selection: $terminalApp) {
                        Text("Terminal").tag("Terminal")
                        Text("iTerm2").tag("iTerm")
                    }
                    TextField("Worktree folder", text: $worktreeRoot)
                }
                Divider()
                Toggle("Notify: commit", isOn: $notifyCommits)
                Toggle("Notify: agent is waiting on you", isOn: $notifyWaiting)
                Toggle("Notify: file conflict", isOn: $notifyConflicts)
            }
            .tabItem { Label("Coordination", systemImage: "person.2") }

            Form {
                Toggle("Generate summary automatically", isOn: $autoSummary)
                HStack {
                    Stepper("Time: \(String(format: "%02d:%02d", summaryHour, summaryMinute))", value: $summaryHour, in: 0...23)
                    Picker("", selection: $summaryMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                    }.frame(width: 80)
                }
                TextField("Folder for .md files", text: $exportDir)
                TextField("Summary model (empty for default)", text: $summaryModel)
                Text("Claude Code writes the summary via `claude -p` from the day’s data: commits, tasks, clients, prompts, and agent replies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Summary", systemImage: "doc.richtext") }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 520)
        .tint(ThemeStore.shared.accent)
    }
}

struct AppearanceSettings: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        Form {
            Section("Color scheme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 12) {
                    ForEach(ThemePreset.allCases) { p in swatch(p) }
                }
                .padding(.vertical, 4)
            }
            Section("Colors") {
                HStack {
                    ColorPicker("Accent color", selection: theme.accentBinding, supportsOpacity: false)
                    if !theme.customAccentHex.isEmpty {
                        Button("Use scheme color") { ThemeStore.animate { theme.customAccentHex = "" } }
                    }
                }
                Picker("Appearance", selection: $theme.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(theme.preset != .system)
                if theme.preset != .system {
                    Text("Light or dark is set by the selected scheme. To choose manually, pick “System”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Interface") {
                Picker("Density", selection: Binding(get: { theme.density }, set: { v in ThemeStore.animate { theme.density = v } })) {
                    ForEach(Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Cards", selection: Binding(get: { theme.cardStyle }, set: { v in ThemeStore.animate { theme.cardStyle = v } })) {
                    ForEach(CardStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Animations", isOn: $theme.animations)
                Toggle("Pulse on active agents", isOn: $theme.pulse).disabled(!theme.animations)
                Button("Reset all dashboard layouts") {
                    ThemeStore.animate { LayoutStore.shared.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
    }

    func swatch(_ p: ThemePreset) -> some View {
        let pal = p.palette
        let bg = Color(hex: pal.bg) ?? Color(nsColor: .windowBackgroundColor)
        let surface = Color(hex: pal.surface) ?? Color(nsColor: .controlBackgroundColor)
        let accent = Color(hex: pal.accent) ?? .accentColor
        let selected = theme.preset == p
        return Button {
            ThemeStore.animate { theme.preset = p }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(bg)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(accent).frame(width: 36, height: 6)
                        RoundedRectangle(cornerRadius: 4).fill(surface).frame(height: 16)
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4).fill(surface).frame(height: 14)
                            RoundedRectangle(cornerRadius: 4).fill(surface).frame(height: 14)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? theme.accent : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
                Text(p.label).font(.caption.weight(selected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(selected ? 1.03 : 1)
        .animation(theme.anim(), value: selected)
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = store.activeAgents().count
        let attention = store.waitingCount
        HStack(spacing: 3) {
            if attention > 0 { Image(systemName: "exclamationmark.bubble.fill") } else { Image(nsImage: Logo.menuBarImage) }
            if active > 0 { Text("\(active)") }
        }
        .onChange(of: store.openMainTick) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AgentBoard").font(.headline)
                Spacer()
                Circle().fill(store.serverRunning ? Color.green : Color.red).frame(width: 7, height: 7)
            }
            ForEach(store.pending) { p in
                ApprovalRow(item: p, compact: true)
                Divider()
            }
            let active = store.activeAgents()
            if active.isEmpty {
                Text("No active agents").foregroundStyle(.secondary)
            } else {
                ForEach(active.prefix(12)) { a in
                    let st = store.status(a)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: st.icon).foregroundStyle(st.color).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(a.name) · \(store.project(a.projectId)?.name ?? "")").font(.callout.weight(.medium))
                            Text(!a.narrative.isEmpty ? a.narrative : a.lastAction.isEmpty ? st.label : a.lastAction)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(Fmt.rel(a.lastSeen, now: store.now)).font(.caption2).foregroundStyle(.secondary)
                    }
                }.feedRowTransition()
            }
            Divider()
            HStack {
                Button("Open dashboard") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Today’s summary") { store.generateSummary(day: Date()) }
                    .disabled(store.generatingDays.contains(Fmt.dayKey.string(from: Date())))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
            }
        }
        .padding(14)
        .frame(width: 400)
        .tint(ThemeStore.shared.accent)
        .preferredColorScheme(ThemeStore.shared.colorScheme)
        .animation(ThemeStore.shared.anim(), value: store.pending.count)
        .animation(ThemeStore.shared.anim(), value: store.activeAgents().map(\.id))
    }
}
