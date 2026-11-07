import AppKit
import SwiftUI

enum NavItem: Hashable {
    case overview, history, summaries, integrations
    case project(String)
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var theme = ThemeStore.shared
    @State private var selection: NavItem? = .overview
    @State private var addError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Обзор", systemImage: "square.grid.2x2").tag(NavItem.overview)
                    Label("История", systemImage: "calendar").tag(NavItem.history)
                    Label("Сводки", systemImage: "doc.richtext").tag(NavItem.summaries)
                    Label("Подключения", systemImage: "point.3.connected.trianglepath.dotted").tag(NavItem.integrations)
                }
                Section("Проекты") {
                    ForEach(store.orderedProjects) { p in
                        HStack {
                            Label(p.name, systemImage: "folder")
                            Spacer()
                            let active = store.activeAgents(in: p.id)
                            let waiting = active.filter { store.status($0) == .waiting }.count
                            if waiting > 0 {
                                Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.caption)
                            }
                            if !active.isEmpty {
                                Text("\(active.count)").font(.caption.monospacedDigit())
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                            }
                        }
                        .tag(NavItem.project(p.id))
                    }
                    .onMove { store.moveProjects(from: $0, to: $1) }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { addProject() } label: { Label("Добавить проект", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Circle().fill(store.serverRunning ? Color.green : Color.red).frame(width: 7, height: 7)
                        .help(store.serverRunning ? "Сервер работает на 127.0.0.1:\(AppSettings.port)" : "Сервер не запущен")
                }
                .padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                if let err = store.serverError {
                    Banner(text: err, color: .red, icon: "exclamationmark.octagon")
                }
                if let err = store.lastError {
                    Banner(text: err, color: .orange, icon: "exclamationmark.triangle") { store.lastError = nil }
                }
                if !store.pending.isEmpty && !isDashboard {
                    ApprovalsBanner().transition(.move(edge: .top).combined(with: .opacity))
                }
                Group {
                    switch selection ?? .overview {
                    case .overview: OverviewView(selection: $selection)
                    case .history: HistoryView()
                    case .summaries: SummariesView()
                    case .integrations: IntegrationsView()
                    case .project(let id): ProjectView(projectId: id).id(id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selection)
                .transition(.opacity)
            }
            .background(theme.background ?? Color.clear)
            .animation(theme.anim(), value: store.pending.count)
            .animation(theme.anim(.easeInOut(duration: 0.2)), value: selection)
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .alert("Не удалось добавить проект", isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })) {
            Button("OK") { addError = nil }
        } message: { Text(addError ?? "") }
    }

    /// Dashboards show approvals as a widget, so the banner isn't duplicated there.
    var isDashboard: Bool {
        if case .overview = selection ?? .overview { return true }
        if case .project = selection, UserDefaults.standard.integer(forKey: "projectTab") == 0 { return true }
        return false
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить"
        panel.message = "Выберите папку проекта (git-репозиторий), над которым работают агенты"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addProject(path: url.path) { err in
            if let err { addError = err }
            else if let p = store.projects.last(where: { $0.path.hasSuffix(url.lastPathComponent) }) { selection = .project(p.id) }
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    let icon: String
    var onClose: (() -> Void)?
    var body: some View {
        HStack {
            Image(systemName: icon)
            Text(text).lineLimit(3)
            Spacer()
            if let onClose { Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
        }
        .padding(10)
        .foregroundStyle(color)
        .background(color.opacity(0.1))
    }
}

struct ApprovalsBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.pending) { p in ApprovalRow(item: p) }
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
    }
}

struct ApprovalRow: View {
    @EnvironmentObject var store: Store
    let item: PendingCommit
    var compact = false
    @State private var comment = ""
    @State private var showStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: "arrow.up.doc.fill").foregroundStyle(.purple).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(item.agentName) хочет сделать коммит · \(item.projectName)").font(.headline)
                    Text(item.command).font(.system(.caption, design: .monospaced)).lineLimit(compact ? 2 : 4)
                        .textSelection(.enabled)
                    let left = max(0, Int(item.deadline - store.now.timeIntervalSince1970))
                    Text("Без решения через \(left / 60):\(String(format: "%02d", left % 60)) вопрос уйдёт в терминал")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !compact {
                DisclosureGroup("Изменения (git status)", isExpanded: $showStatus) {
                    ScrollView {
                        Text(item.gitStatus.isEmpty ? "нет данных" : item.gitStatus)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.frame(maxHeight: 160)
                }.font(.caption)
            }
            HStack {
                TextField("Комментарий агенту (необязательно)", text: $comment).textFieldStyle(.roundedBorder)
                Button("Отклонить", role: .destructive) { store.decide(item.id, allow: false, comment: comment) }
                Button("Разрешить") { store.decide(item.id, allow: true, comment: comment) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
