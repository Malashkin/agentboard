import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: Store
    @Binding var selection: NavItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Обзор").font(.largeTitle.bold())
                if store.projects.isEmpty {
                    Onboarding(selection: $selection)
                } else {
                    let active = store.activeAgents()
                    HStack(spacing: 12) {
                        StatTile(title: "Агентов работает", value: "\(active.count)", icon: "person.2.wave.2", color: .green)
                        StatTile(title: "Ждут вас", value: "\(store.waitingCount)", icon: "hand.raised", color: .orange)
                        StatTile(title: "Коммитов сегодня", value: "\(store.git.values.reduce(0) { $0 + $1.todayCommits.count })",
                                 icon: "checkmark.seal", color: .purple)
                        StatTile(title: "Задач закрыто сегодня", value: "\(store.tasks.filter { ($0.doneAt ?? 0) >= Calendar.current.startOfDay(for: store.now).timeIntervalSince1970 }.count)",
                                 icon: "checklist.checked", color: .blue)
                    }
                    Text("Агенты").font(.title2.bold())
                    AgentsGrid(projectId: nil, showProject: true)
                    Text("Лента").font(.title2.bold())
                    FeedList(projectId: nil, limit: 60)
                }
            }
            .padding(20)
        }
    }
}

struct Onboarding: View {
    @EnvironmentObject var store: Store
    @Binding var selection: NavItem?
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Как начать").font(.title2.bold())
                Label("Откройте «Подключения» и подключите Claude Code (хуки + MCP) и, если пользуетесь, Codex.", systemImage: "1.circle.fill")
                Label("Добавьте проект — папку git-репозитория, над которым работают агенты (кнопка внизу слева).", systemImage: "2.circle.fill")
                Label("Запускайте Claude Code в разных терминалах в этой папке или её worktree — агенты появятся здесь и будут видеть друг друга.", systemImage: "3.circle.fill")
                Label("Вечером AgentBoard соберёт сводку: что сделано по коду и по клиентам.", systemImage: "4.circle.fill")
                Button("Открыть подключения") { selection = .integrations }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ProjectView: View {
    @EnvironmentObject var store: Store
    let projectId: String
    @State private var tab = 0

    var body: some View {
        if let p = store.project(projectId) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.name).font(.title.bold())
                            if !p.client.isEmpty { Pill(text: p.client, color: .accentColor, icon: "person.crop.square") }
                        }
                        Text(p.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Picker("", selection: $tab) {
                        Text("Агенты").tag(0)
                        Text("Задачи").tag(1)
                        Text("Лента").tag(2)
                        Text("Git").tag(3)
                        Text("Настройки").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 440)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
                switch tab {
                case 0: ScrollView { AgentsGrid(projectId: p.id).padding(20) }
                case 1: BoardView(projectId: p.id)
                case 2: ScrollView { FeedList(projectId: p.id, limit: 500, showComposer: true).padding(20) }
                case 3: GitView(projectId: p.id)
                default: ProjectSettingsView(project: p)
                }
            }
        } else {
            Text("Проект не найден").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Feed

struct FeedList: View {
    @EnvironmentObject var store: Store
    let projectId: String?
    var limit = 200
    var showComposer = false
    @State private var showRoutine = false
    @State private var search = ""
    @State private var expanded: Set<Int64> = []
    @State private var note = ""

    var items: [EventItem] {
        store.events.lazy
            .filter { projectId == nil || $0.projectId == projectId }
            .filter { showRoutine || !$0.isRoutine }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }
            .prefix(limit).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showComposer, let projectId {
                HStack {
                    TextField("Заметка в ленту (видна агентам в board)…", text: $note).textFieldStyle(.roundedBorder)
                        .onSubmit { post(projectId) }
                    Button("Добавить") { post(projectId) }.disabled(note.trimmed.isEmpty)
                }
            }
            HStack {
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Все действия (запросы, команды, правки)", isOn: $showRoutine).toggleStyle(.checkbox)
                Spacer()
            }
            if items.isEmpty {
                Text("Событий пока нет").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { e in
                    row(e)
                    Divider()
                }
            }
        }
    }

    func post(_ projectId: String) {
        guard !note.trimmed.isEmpty else { return }
        store.addNote(project: projectId, text: note.trimmed, client: store.project(projectId)?.client ?? "")
        note = ""
    }

    @ViewBuilder func row(_ e: EventItem) -> some View {
        let isOpen = expanded.contains(e.id)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.icon).foregroundStyle(e.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.title).lineLimit(isOpen ? nil : 2).textSelection(.enabled)
                    if !e.client.isEmpty { Pill(text: e.client, color: .accentColor) }
                }
                HStack(spacing: 6) {
                    if projectId == nil, let p = store.project(e.projectId) { Text(p.name) }
                    if let n = store.agentName(e.agentId) { Text("· \(n)") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if isOpen && !e.detail.isEmpty {
                    Text(e.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
            Spacer()
            Text(Fmt.day(e.createdAt) == Fmt.day(store.now.timeIntervalSince1970) ? Fmt.time(e.createdAt) : Fmt.rel(e.createdAt, now: store.now))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !e.detail.isEmpty else { return }
            if isOpen { expanded.remove(e.id) } else { expanded.insert(e.id) }
        }
    }
}

// MARK: - Git

struct GitView: View {
    @EnvironmentObject var store: Store
    let projectId: String

    var body: some View {
        let snap = store.git[projectId] ?? GitSnapshot()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let err = snap.error { Banner(text: err, color: .orange, icon: "exclamationmark.triangle") }
                HStack {
                    Text("Рабочие копии").font(.title2.bold())
                    Spacer()
                    Button { GitMonitor.shared.refreshNow() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                }
                ForEach(snap.worktrees) { w in
                    let owner = store.agents(in: projectId).first { $0.isActive(staleMinutes: store.staleMinutes, at: store.now) && ($0.root == w.path || $0.cwd.hasPrefix(w.path)) }
                    Card(tint: w.changes.isEmpty ? .clear : .orange) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Pill(text: w.branch, color: .purple, icon: "arrow.triangle.branch")
                                if w.ahead > 0 { Pill(text: "↑\(w.ahead) не запушено", color: .blue) }
                                if w.behind > 0 { Pill(text: "↓\(w.behind)", color: .gray) }
                                if let owner { Pill(text: owner.name, color: .green, icon: "person") }
                                Spacer()
                                Text(w.changes.isEmpty ? "чисто" : "\(w.changes.count) незакоммиченных")
                                    .font(.caption).foregroundStyle(w.changes.isEmpty ? Color.secondary : Color.orange)
                            }
                            Text(w.path).font(.caption).foregroundStyle(.secondary)
                            if !w.changes.isEmpty {
                                Text(w.changes.prefix(30).joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
                Text("Коммиты сегодня").font(.title2.bold())
                if snap.todayCommits.isEmpty { Text("Пока нет").foregroundStyle(.secondary) }
                ForEach(snap.todayCommits) { c in
                    let agentEvent = store.events.first { $0.kind == "commit" && $0.ref.hasPrefix(c.hash) }
                    HStack(alignment: .top, spacing: 10) {
                        Text(c.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(c.hash).font(.caption.monospaced()).foregroundStyle(.purple)
                        Text(c.subject).textSelection(.enabled)
                        Spacer()
                        if let n = store.agentName(agentEvent?.agentId) { Pill(text: n, color: .green, icon: "person") }
                        Text(c.author).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Project settings

struct ProjectSettingsView: View {
    @EnvironmentObject var store: Store
    let project: Project
    @State private var name = ""
    @State private var client = ""
    @State private var gitHook = false
    @State private var agentsMd = false
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Проект") {
                TextField("Название", text: $name)
                TextField("Клиент по умолчанию", text: $client)
                Text("Клиент подставляется в новые задачи и помогает группировать сводку по клиентам.").font(.caption).foregroundStyle(.secondary)
                Button("Сохранить") { store.updateProject(project.id, name: name, client: client) }
            }
            Section("Подключение проекта") {
                LabeledContent("git post-commit хук") {
                    HStack {
                        Text(gitHook ? "установлен" : "нет").foregroundStyle(gitHook ? .green : .orange)
                        Button(gitHook ? "Удалить" : "Установить") {
                            if gitHook { Integrations.uninstallGitHook(project) } else {
                                do { try Integrations.installGitHook(project) } catch { message = error.localizedDescription }
                            }
                            refresh()
                        }
                    }
                }
                Text("Ловит коммиты любого агента (включая Codex) во всех worktree проекта.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Правила в AGENTS.md") {
                    HStack {
                        Text(agentsMd ? "добавлены" : "нет").foregroundStyle(agentsMd ? .green : .secondary)
                        if !agentsMd {
                            Button("Добавить") {
                                do { try Integrations.installAgentsMd(project) } catch { message = error.localizedDescription }
                                refresh()
                            }
                        }
                    }
                }
                Text("Нужно для Codex и других агентов без хуков: объясняет им, как пользоваться доской. Claude Code получает правила автоматически.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Агенты") {
                Button("Убрать завершённых и неактивных агентов") { store.purgeAgents(project: project.id) }
            }
            Section {
                Button("Удалить проект из AgentBoard", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = project.name; client = project.client; refresh() }
        .confirmationDialog("Удалить «\(project.name)» из AgentBoard?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) {
                Integrations.uninstallGitHook(project)
                store.removeProject(project.id)
            }
        } message: { Text("История агентов, задачи и лента проекта будут удалены. Файлы проекта не трогаются.") }
        .alert("Ошибка", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func refresh() {
        gitHook = Integrations.gitHookInstalled(project)
        agentsMd = Integrations.agentsMdInstalled(project)
    }
}
