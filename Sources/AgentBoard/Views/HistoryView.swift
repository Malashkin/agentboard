import SwiftUI

/// Work of all agents on any past day, read directly from the database (not limited to the live window).
struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var day = Date()
    @State private var projectId = ""
    @State private var days: [Core.DayActivity] = []
    @State private var history = Core.History(agents: [], events: [], tasksDone: [])
    @State private var showRoutine = false
    @State private var loading = false
    @State private var expanded: Set<String> = []

    var dayKey: String { Fmt.dayKey.string(from: day) }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Дни с активностью").font(.headline)
                List(days, selection: Binding(get: { dayKey }, set: { k in
                    if let k, let d = Fmt.dayKey.date(from: k) { day = d }
                })) { d in
                    HStack {
                        Text(Self.dayTitle(d.day)).font(.callout)
                        Spacer()
                        Text("\(d.agents) аг. · \(d.events)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(d.day)
                }
                .listStyle(.inset)
                if days.isEmpty {
                    Text("Пока пусто — история появится, когда агенты начнут работать в добавленных проектах.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if history.events.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("В этот день агенты не работали").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { content.padding(20) }
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reload() }
        .onChange(of: day) { load() }
        .onChange(of: projectId) { load() }
    }

    var header: some View {
        HStack(spacing: 8) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date).labelsHidden().frame(width: 130)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(day))
            Button("Сегодня") { day = Date() }
            Picker("", selection: $projectId) {
                Text("Все проекты").tag("")
                ForEach(store.projects) { Text($0.name).tag($0.id) }
            }
            .frame(width: 200)
            Toggle("Все действия", isOn: $showRoutine).toggleStyle(.checkbox)
            Spacer()
            if let s = store.summaries.first(where: { $0.day == dayKey }) {
                Button { copyToPasteboard(s.markdown) } label: { Label("Копировать сводку", systemImage: "doc.on.doc") }
            } else {
                Button { store.generateSummary(day: day) } label: {
                    Label(store.generatingDays.contains(dayKey) ? "Пишется…" : "Сводка за день", systemImage: "doc.richtext")
                }
                .disabled(store.generatingDays.contains(dayKey))
            }
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
        }
        .padding(12)
    }

    @ViewBuilder var content: some View {
        let ev = history.events
        VStack(alignment: .leading, spacing: 16) {
            Text(Fmt.dayHuman.string(from: day).capitalized).font(.title.bold())
            HStack(spacing: 12) {
                StatTile(title: "Агентов", value: history.agents.count, icon: "person.2", color: .green)
                StatTile(title: "Запросов", value: ev.filter { $0.kind == "prompt" }.count, icon: "text.bubble", color: .blue)
                StatTile(title: "Коммитов", value: ev.filter { $0.kind == "commit" }.count, icon: "checkmark.seal", color: .purple)
                StatTile(title: "Задач закрыто", value: history.tasksDone.count, icon: "checklist.checked", color: .orange)
            }
            if let s = store.summaries.first(where: { $0.day == dayKey }) {
                DisclosureGroup("Сводка дня") { MarkdownView(text: s.markdown).padding(.top, 8) }
                    .font(.headline)
            }
            let clients = Set(ev.map(\.client).filter { !$0.isEmpty } + history.tasksDone.map(\.client).filter { !$0.isEmpty })
            if !clients.isEmpty {
                HStack { Text("Клиенты:").foregroundStyle(.secondary); ForEach(clients.sorted(), id: \.self) { Pill(text: $0, color: .accentColor) } }
            }
            if !history.tasksDone.isEmpty {
                Text("Закрытые задачи").font(.title3.bold())
                ForEach(history.tasksDone) { t in
                    HStack {
                        Text("#\(t.id)").foregroundStyle(.secondary)
                        Text(t.title)
                        if !t.client.isEmpty { Pill(text: t.client, color: .accentColor) }
                        Spacer()
                        if let n = history.agents.first(where: { $0.id == t.assignee })?.name { Pill(text: n, color: .green) }
                    }
                }
            }
            Text("Агенты").font(.title3.bold())
            ForEach(history.agents.sorted { first($0) < first($1) }) { a in agentSection(a) }
            let human = ev.filter { $0.agentId == nil && (showRoutine || !$0.isRoutine) }
            if !human.isEmpty {
                Text("Ваши действия и системные события").font(.title3.bold())
                timeline(human)
            }
        }
    }

    func first(_ a: Agent) -> Double { history.events.first { $0.agentId == a.id }?.createdAt ?? 0 }

    @ViewBuilder func agentSection(_ a: Agent) -> some View {
        let all = history.events.filter { $0.agentId == a.id }
        let shown = all.filter { showRoutine || !$0.isRoutine || $0.kind == "prompt" || $0.kind == "turn_done" }
        let isOpen = expanded.contains(a.id)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: a.toolIcon)
                    Text(a.name).font(.headline)
                    Pill(text: a.toolLabel)
                    if let p = store.project(a.projectId) { Pill(text: p.name, color: .accentColor, icon: "folder") }
                    if !a.branch.isEmpty { Pill(text: a.branch, color: .purple, icon: "arrow.triangle.branch") }
                    Spacer()
                    if let f = all.first, let l = all.last {
                        Text("\(Fmt.time(f.createdAt))–\(Fmt.time(l.createdAt))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    Label("\(all.filter { $0.kind == "prompt" }.count) запросов", systemImage: "text.bubble")
                    Label("\(all.filter { $0.kind == "action" }.count) действий", systemImage: "terminal")
                    Label("\(all.filter { $0.kind == "commit" }.count) коммитов", systemImage: "checkmark.seal")
                    if all.contains(where: { $0.kind == "conflict" }) {
                        Label("конфликты", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .smoothNumber(all.count)
                Button(isOpen ? "Свернуть" : "Показать хронологию (\(shown.count))") {
                    if isOpen { expanded.remove(a.id) } else { expanded.insert(a.id) }
                }
                .buttonStyle(.link)
                if isOpen { timeline(shown) }
            }
        }
    }

    func timeline(_ items: [EventItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { e in
                HStack(alignment: .top, spacing: 8) {
                    Text(Fmt.time(e.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    Image(systemName: e.icon).foregroundStyle(e.color).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((e.sub.isEmpty || e.title.hasPrefix("↳") ? "" : "↳ \(e.sub): ") + e.title).font(.callout).textSelection(.enabled)
                        if (e.kind == "turn_done" || e.kind == "commit" || e.kind == "note") && !e.detail.isEmpty {
                            Text(e.detail.trunc(1200)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }.feedRowTransition()
            .animateRows(items.map(\.id))
        }
    }

    static func dayTitle(_ key: String) -> String {
        guard let d = Fmt.dayKey.date(from: key) else { return key }
        if Calendar.current.isDateInToday(d) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(d) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, EE"
        return f.string(from: d)
    }

    func shift(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: n, to: day), d <= Date() { day = d }
    }

    func reload() {
        Core.shared.q.async {
            let d = Core.shared.activeDays()
            DispatchQueue.main.async { ThemeStore.animate { days = d } }
        }
        load()
    }

    func load() {
        loading = true
        let (from, to) = SummaryService.dayRange(day)
        let pid = projectId.isEmpty ? nil : projectId
        Core.shared.q.async {
            let h = Core.shared.history(from: from, to: to, project: pid)
            DispatchQueue.main.async { ThemeStore.animate { history = h }; loading = false }
        }
    }
}
