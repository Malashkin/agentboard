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
                DatePicker("День", selection: $day, in: ...Date(), displayedComponents: .date)
                let key = Fmt.dayKey.string(from: day)
                Button {
                    store.generateSummary(day: day)
                } label: {
                    HStack {
                        if store.generatingDays.contains(key) { ProgressView().controlSize(.small) }
                        Text(store.generatingDays.contains(key) ? "Claude пишет сводку…" : "Сгенерировать сводку")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.generatingDays.contains(key))
                Text(AppSettings.autoSummary ? "Автоматически каждый день в \(String(format: "%02d:%02d", AppSettings.summaryHour, AppSettings.summaryMinute))" : "Автосводка выключена")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $selected) {
                    ForEach(store.summaries) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.day).font(.headline)
                            Text("\(Fmt.time(s.createdAt)) · \(s.source == "claude" ? "Claude" : s.source == "raw" ? "только факты" : "пусто")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(s.id)
                        .contextMenu { Button("Удалить", role: .destructive) { store.deleteSummary(s.id) } }
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
                            Text("Сводка за \(s.day)").font(.headline)
                            Spacer()
                            Button { copyToPasteboard(s.markdown) } label: { Label("Копировать", systemImage: "doc.on.doc") }
                            Button {
                                let path = SummaryService.export(s) ?? SummaryService.exportPath(s)
                                revealInFinder(path)
                            } label: { Label("Показать файл", systemImage: "folder") }
                        }
                        .padding(12)
                        Divider()
                        ScrollView { MarkdownView(text: s.markdown).padding(24).frame(maxWidth: 860, alignment: .leading) }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.richtext").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Сводок пока нет").font(.headline)
                        Text("Выберите день и нажмите «Сгенерировать сводку». Нужен установленный Claude Code (claude -p).")
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
                Text("Подключения").font(.largeTitle.bold())
                Text("AgentBoard связан с агентами в обе стороны: хуки сообщают панели, что делает каждый терминал, и доставляют агентам ваши сообщения; MCP-сервер даёт агентам видеть доску, друг друга и договариваться.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                IntegrationRow(
                    title: "Claude Code — хуки",
                    detail: "Глобально в ~/.claude/settings.json (с резервной копией). Срабатывают только в проектах, добавленных в AgentBoard. Дают: статус каждого терминала в реальном времени, перехват git commit, предупреждения о конфликтах файлов, доставку сообщений агенту, правила совместной работы в начале сессии.",
                    installed: hooks, busy: busy,
                    install: { run { try Integrations.installClaudeHooks() } },
                    uninstall: { run { try Integrations.uninstallClaudeHooks() } })

                IntegrationRow(
                    title: "Claude Code — MCP-сервер agentboard",
                    detail: "claude mcp add --scope user agentboard \(Integrations.mcpURL). Инструменты: board, agent_activity, send_message, claim_task, create_task, update_task, set_focus, post_note, who_touches. Скажите агенту «посмотри, что делает Вега» — он вызовет agent_activity.",
                    installed: mcp, busy: busy,
                    install: { run { try Integrations.installClaudeMCP() } },
                    uninstall: { run { Integrations.uninstallClaudeMCP() } })

                IntegrationRow(
                    title: "Codex",
                    detail: codexAvailable
                        ? "Добавляет MCP-сервер agentboard и notify в ~/.codex/config.toml (с резервной копией). Codex видит доску через MCP, панель видит каждый его ход. Добавьте также правила в AGENTS.md в настройках проекта."
                        : "Codex не найден на этом Mac. Можно подключить заранее — настройка запишется в ~/.codex/config.toml.",
                    installed: codex, busy: busy,
                    install: { run { try Integrations.installCodex() } },
                    uninstall: nil)

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Технические детали").font(.headline)
                        LabeledContent("Сервер") {
                            Text(store.serverRunning ? "работает · http://127.0.0.1:\(AppSettings.port)" : "не запущен")
                                .foregroundStyle(store.serverRunning ? .green : .red)
                        }
                        LabeledContent("Скрипт-мост") { Text(Integrations.hookPath).textSelection(.enabled) }
                        LabeledContent("База") { Text(Core.shared.supportDir.path).textSelection(.enabled) }
                        Text("Если приложение закрыто, хуки молча ничего не делают и агентам не мешают.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: refresh)
        .alert("Подключения", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
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
                message = err ?? "Готово. Уже открытые сессии Claude Code подхватят изменения после перезапуска."
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
                    Button(installed ? "Переустановить" : "Подключить") { install() }
                        .buttonStyle(.borderedProminent).disabled(busy)
                    if installed, let uninstall { Button("Отключить") { uninstall() }.disabled(busy) }
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

    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Оформление", systemImage: "paintpalette") }

            Form {
                Toggle("Запускать при входе в систему", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                Stepper("Агент неактивен после \(Int(staleMinutes)) мин тишины", value: $staleMinutes, in: 5...240, step: 5)
                TextField("Порт локального сервера", value: $port, format: .number.grouping(.never))
                Text("После смены порта перезапустите приложение и переподключите MCP в «Подключениях».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Общие", systemImage: "gearshape") }

            Form {
                Picker("Когда агент делает git commit", selection: $commitMode) {
                    ForEach(CommitMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Stepper("Ждать решения \(Int(approvalTimeout)) с, затем спросить в терминале",
                        value: $approvalTimeout, in: 30...1800, step: 30)
                    .disabled(commitMode != CommitMode.approve.rawValue)
                Text("Режим «Спрашивать одобрение» останавливает агента перед коммитом, пока вы не нажмёте «Разрешить» в окне или в меню-баре. После изменения таймаута переустановите хуки.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Коммиты", systemImage: "checkmark.seal") }

            Form {
                Toggle("Сообщать агенту, что делают другие (при каждом новом запросе, если что-то изменилось)", isOn: $injectContext)
                Toggle("Предупреждать агента о правке чужих файлов", isOn: $conflictWarnings)
                Divider()
                Toggle("Уведомление: коммит", isOn: $notifyCommits)
                Toggle("Уведомление: агент ждёт вас", isOn: $notifyWaiting)
                Toggle("Уведомление: конфликт файлов", isOn: $notifyConflicts)
            }
            .tabItem { Label("Координация", systemImage: "person.2") }

            Form {
                Toggle("Делать сводку автоматически", isOn: $autoSummary)
                HStack {
                    Stepper("Время: \(String(format: "%02d:%02d", summaryHour, summaryMinute))", value: $summaryHour, in: 0...23)
                    Picker("", selection: $summaryMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                    }.frame(width: 80)
                }
                TextField("Папка для .md файлов", text: $exportDir)
                TextField("Модель для сводки (пусто — по умолчанию)", text: $summaryModel)
                Text("Сводку пишет Claude Code через `claude -p` по данным дня: коммиты, задачи, клиенты, запросы и ответы агентов.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Сводка", systemImage: "doc.richtext") }
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
            Section("Цветовая схема") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 12) {
                    ForEach(ThemePreset.allCases) { p in swatch(p) }
                }
                .padding(.vertical, 4)
            }
            Section("Цвета") {
                HStack {
                    ColorPicker("Акцентный цвет", selection: theme.accentBinding, supportsOpacity: false)
                    if !theme.customAccentHex.isEmpty {
                        Button("Как в схеме") { ThemeStore.animate { theme.customAccentHex = "" } }
                    }
                }
                Picker("Оформление", selection: $theme.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(theme.preset != .system)
                if theme.preset != .system {
                    Text("Светлое/тёмное задаёт выбранная схема. Для выбора вручную возьмите «Системную».")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Интерфейс") {
                Picker("Плотность", selection: Binding(get: { theme.density }, set: { v in ThemeStore.animate { theme.density = v } })) {
                    ForEach(Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Карточки", selection: Binding(get: { theme.cardStyle }, set: { v in ThemeStore.animate { theme.cardStyle = v } })) {
                    ForEach(CardStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Анимации", isOn: $theme.animations)
                Toggle("Пульсация у работающих агентов", isOn: $theme.pulse).disabled(!theme.animations)
                Button("Сбросить расположение всех панелей") {
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
                Text("Активных агентов нет").foregroundStyle(.secondary)
            } else {
                ForEach(active.prefix(12)) { a in
                    let st = store.status(a)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: st.icon).foregroundStyle(st.color).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(a.name) · \(store.project(a.projectId)?.name ?? "")").font(.callout.weight(.medium))
                            Text(a.lastAction.isEmpty ? st.label : a.lastAction).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.rel(a.lastSeen, now: store.now)).font(.caption2).foregroundStyle(.secondary)
                    }
                }.feedRowTransition()
            }
            Divider()
            HStack {
                Button("Открыть панель") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Сводка за сегодня") { store.generateSummary(day: Date()) }
                    .disabled(store.generatingDays.contains(Fmt.dayKey.string(from: Date())))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Выйти")
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
