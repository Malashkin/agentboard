import SwiftUI

struct AgentCard: View {
    @EnvironmentObject var store: Store
    let agent: Agent
    var showProject = false
    var onOpen: () -> Void = {}
    var onMessage: () -> Void = {}

    var body: some View {
        let st = store.status(agent)
        Card(tint: st == .ended || st == .stale ? .clear : st.color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: agent.toolIcon).foregroundStyle(.secondary)
                        .symbolEffect(.pulse, isActive: st == .working && ThemeStore.shared.animations)
                    Text(agent.name).font(.headline)
                    Pill(text: agent.toolLabel)
                    Spacer()
                    StatusBadge(status: st)
                }
                HStack(spacing: 6) {
                    if showProject, let p = store.project(agent.projectId) { Pill(text: p.name, color: .accentColor, icon: "folder") }
                    if !agent.branch.isEmpty { Pill(text: agent.branch, color: .purple, icon: "arrow.triangle.branch") }
                    let unread = store.undelivered(to: agent.id)
                    if unread > 0 { Pill(text: "\(unread) не доставлено", color: .teal, icon: "envelope") }
                }
                if let t = store.currentTask(of: agent.id) {
                    Label("#\(t.id) \(t.title)" + (t.client.isEmpty ? "" : " · \(t.client)"), systemImage: "checklist")
                        .font(.callout).lineLimit(2)
                }
                if !agent.focus.isEmpty {
                    Label(agent.focus, systemImage: "scope").font(.callout).lineLimit(2)
                }
                // Fixed height, so a new prompt doesn't resize the card and reflow the grid.
                Text(agent.lastPrompt.isEmpty ? " " : "«\(agent.lastPrompt.oneLine)»").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .contentTransition(.opacity)
                let files = store.files(of: agent.id).prefix(4).map(\.path)
                if !files.isEmpty {
                    Text(files.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "bolt").foregroundStyle(.secondary)
                    Text(agent.lastAction.isEmpty ? "—" : agent.lastAction).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(Fmt.rel(agent.lastSeen, now: store.now)).foregroundStyle(.secondary)
                    Button { onMessage() } label: { Image(systemName: "text.bubble") }
                        .buttonStyle(.borderless).help("Комментарий в сессию агента")
                }
                .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

struct AgentsGrid: View {
    @EnvironmentObject var store: Store
    let projectId: String?
    var showProject = false
    @State private var showEnded = false
    @State private var detail: Agent?
    @State private var messageTo: MessageTarget?

    var list: [Agent] {
        let all = projectId.map { store.agents(in: $0) } ?? store.agents
        let filtered = showEnded ? all : all.filter { $0.isActive(staleMinutes: store.staleMinutes, at: store.now) }
        // Stable order (by session start): cards must not jump around while agents work.
        return filtered.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Показывать завершённые и неактивные", isOn: $showEnded).toggleStyle(.checkbox)
                Spacer()
                if let projectId {
                    Button { messageTo = MessageTarget(projectId: projectId, agent: nil) } label: {
                        Label("Написать всем агентам", systemImage: "megaphone")
                    }
                }
            }
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Активных агентов нет").font(.headline)
                    Text("Запустите Claude Code в папке проекта — агент появится здесь автоматически.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(list) { a in
                        AgentCard(agent: a, showProject: showProject,
                                  onOpen: { detail = a },
                                  onMessage: { messageTo = MessageTarget(projectId: a.projectId, agent: a.id) })
                            .hoverLift()
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
            }
        }
        .sheet(item: $detail) { a in AgentDetailSheet(agentId: a.id) }
        .sheet(item: $messageTo) { t in MessageSheet(target: t) }
    }
}

struct MessageTarget: Identifiable {
    var projectId: String
    var agent: String?
    var id: String { projectId + (agent ?? "*") }
}

struct MessageSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let target: MessageTarget
    @State private var text = ""
    @State private var mode: DeliveryMode = .auto
    @State private var sending = false
    @State private var result: String?

    var body: some View {
        let a = store.agent(target.agent)
        VStack(alignment: .leading, spacing: 12) {
            if let a {
                HStack {
                    Text("Комментарий в сессию \(a.name)").font(.title3.bold())
                    Pill(text: a.toolLabel)
                    StatusBadge(status: store.status(a))
                }
                if !a.lastAction.isEmpty {
                    Text("Сейчас: \(a.lastAction)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("Сообщение всем активным агентам проекта").font(.title3.bold())
                Text("Каждый агент получит его в контекст на ближайшем шаге или при следующем запросе.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $text).font(.body).frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            if a != nil {
                Picker("Доставка", selection: $mode) {
                    ForEach(DeliveryMode.allCases) { Text($0.label).tag($0) }
                }
                Text(mode.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let result {
                Label(result, systemImage: "info.circle").font(.callout).foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button(result == nil ? "Отмена" : "Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("Отправить") { send(a) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmed.isEmpty || sending)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func send(_ a: Agent?) {
        let body = text.trimmed
        guard let a else {
            store.sendMessage(project: target.projectId, to: nil, text: body)
            dismiss()
            return
        }
        sending = true
        SessionDelivery.deliver(agentId: a.id, text: body, mode: mode) { r in
            sending = false
            result = r
        }
    }
}

struct AgentDetailSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let agentId: String
    @State private var name = ""
    @State private var messaging = false

    var body: some View {
        if let a = store.agent(agentId) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: a.toolIcon).font(.title2)
                    TextField("Имя", text: $name).font(.title2.bold()).textFieldStyle(.plain)
                        .onSubmit { store.renameAgent(a.id, name) }
                    StatusBadge(status: store.status(a))
                    Spacer()
                    Button("Готово") { if name != a.name { store.renameAgent(a.id, name) }; dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("ID").foregroundStyle(.secondary); Text(a.id).textSelection(.enabled) }
                    GridRow { Text("Инструмент").foregroundStyle(.secondary); Text(a.toolLabel) }
                    GridRow { Text("Папка").foregroundStyle(.secondary); Text(a.cwd).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                    GridRow { Text("Ветка").foregroundStyle(.secondary); Text(a.branch.isEmpty ? "—" : a.branch) }
                    GridRow { Text("Начал").foregroundStyle(.secondary); Text(Fmt.rel(a.startedAt, now: store.now)) }
                    GridRow { Text("Фокус").foregroundStyle(.secondary); Text(a.focus.isEmpty ? "—" : a.focus) }
                }
                .font(.callout)
                if !a.lastPrompt.isEmpty {
                    GroupBox("Последний запрос") {
                        ScrollView { Text(a.lastPrompt).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: 90)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    GroupBox("Файлы") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(store.files(of: a.id)) { f in
                                    HStack {
                                        Text(f.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("×\(f.count)").font(.caption).foregroundStyle(.secondary).smoothNumber(f.count, Double(f.count))
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(width: 260)
                    GroupBox("Хронология") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(store.events.filter { $0.agentId == a.id }.prefix(150)) { e in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(Fmt.time(e.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Image(systemName: e.icon).foregroundStyle(e.color).font(.caption)
                                        Text(e.title).font(.caption).lineLimit(3).textSelection(.enabled)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 280)
                let inbox = store.inbox(of: a.id)
                if !inbox.isEmpty {
                    GroupBox("Сообщения агенту") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(inbox.prefix(6)) { m in
                                HStack(alignment: .top) {
                                    Image(systemName: m.deliveredAt == nil ? "clock" : "checkmark")
                                        .foregroundStyle(m.deliveredAt == nil ? .orange : .green)
                                    Text("\(m.fromLabel): \(m.text)").font(.caption).lineLimit(2)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Button { messaging = true } label: { Label("Комментарий в сессию", systemImage: "text.bubble") }
                    if !a.transcriptPath.isEmpty {
                        Button { revealInFinder(a.transcriptPath) } label: { Label("Транскрипт", systemImage: "doc.text") }
                    }
                    Spacer()
                    if a.status != "ended" {
                        Button("Пометить завершённым") { store.endAgent(a.id) }
                    }
                }
            }
            .padding(20)
            .frame(width: 760)
            .onAppear { name = a.name }
            .sheet(isPresented: $messaging) { MessageSheet(target: MessageTarget(projectId: a.projectId, agent: a.id)) }
        } else {
            Text("Агент не найден").padding(40)
        }
    }
}
