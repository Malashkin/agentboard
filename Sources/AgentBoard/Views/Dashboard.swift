import SwiftUI
import UniformTypeIdentifiers

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case stats, approvals, agents, feed, tasks, commits, clients, hotFiles, summary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stats: return "Показатели"
        case .approvals: return "Ждут решения"
        case .agents: return "Агенты"
        case .feed: return "Лента"
        case .tasks: return "Задачи в работе"
        case .commits: return "Коммиты сегодня"
        case .clients: return "Клиенты сегодня"
        case .hotFiles: return "Горячие файлы"
        case .summary: return "Последняя сводка"
        }
    }
    var icon: String {
        switch self {
        case .stats: return "gauge.with.dots.needle.33percent"
        case .approvals: return "hand.raised"
        case .agents: return "person.2.wave.2"
        case .feed: return "list.bullet.rectangle"
        case .tasks: return "checklist"
        case .commits: return "checkmark.seal"
        case .clients: return "person.crop.square.filled.and.at.rectangle"
        case .hotFiles: return "flame"
        case .summary: return "doc.richtext"
        }
    }
    var defaultWide: Bool { [.stats, .agents, .feed].contains(self) }
}

struct WidgetConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: WidgetKind
    var wide: Bool
}

/// Per-dashboard widget layouts, persisted as JSON.
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()
    @Published private var layouts: [String: [WidgetConfig]] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: "layouts"),
           let l = try? JSONDecoder().decode([String: [WidgetConfig]].self, from: d) {
            layouts = l
        }
    }

    static func defaults(project: Bool) -> [WidgetConfig] {
        let kinds: [WidgetKind] = project
            ? [.approvals, .stats, .agents, .tasks, .hotFiles, .feed, .commits]
            : [.approvals, .stats, .agents, .tasks, .commits, .feed, .clients, .summary]
        return kinds.map { WidgetConfig(kind: $0, wide: $0.defaultWide) }
    }

    func layout(_ key: String) -> [WidgetConfig] {
        layouts[key] ?? Self.defaults(project: key != "overview")
    }

    func set(_ key: String, _ value: [WidgetConfig]) {
        layouts[key] = value
        if let d = try? JSONEncoder().encode(layouts) { UserDefaults.standard.set(d, forKey: "layouts") }
    }

    func resetAll() {
        layouts = [:]
        UserDefaults.standard.removeObject(forKey: "layouts")
    }

    func reset(_ key: String) {
        layouts.removeValue(forKey: key)
        if let d = try? JSONEncoder().encode(layouts) { UserDefaults.standard.set(d, forKey: "layouts") }
    }
}

/// A customizable dashboard: widgets can be dragged, resized (half / full width), hidden and added.
struct Dashboard: View {
    @EnvironmentObject var store: Store
    @ObservedObject var layouts = LayoutStore.shared
    @ObservedObject var theme = ThemeStore.shared
    let key: String
    let projectId: String?
    @Binding var editing: Bool
    @State private var dragging: UUID?
    @State private var dropTarget: UUID?

    var items: [WidgetConfig] { layouts.layout(key) }

    /// Packs widgets into rows: a wide widget takes a row, narrow ones pair up.
    var rows: [[WidgetConfig]] {
        var out: [[WidgetConfig]] = []
        var pendingNarrow: WidgetConfig?
        for w in items where visible(w) {
            if w.wide {
                if let p = pendingNarrow { out.append([p]); pendingNarrow = nil }
                out.append([w])
            } else if let p = pendingNarrow {
                out.append([p, w]); pendingNarrow = nil
            } else {
                pendingNarrow = w
            }
        }
        if let p = pendingNarrow { out.append([p]) }
        return out
    }

    /// Approvals only take space when something is pending (unless editing).
    func visible(_ w: WidgetConfig) -> Bool {
        if w.kind == .approvals && !editing { return store.pending.contains { projectId == nil || $0.projectId == projectId } }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.density.spacing) {
            if editing { editBar.transition(.move(edge: .top).combined(with: .opacity)) }
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: theme.density.spacing) {
                    ForEach(row) { w in widget(w) }
                }
            }
        }
        .animation(theme.anim(), value: items)
        .animation(theme.anim(), value: editing)
    }

    var editBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw").foregroundStyle(theme.accent)
            Text("Перетаскивайте виджеты, меняйте ширину и скрывайте лишнее").font(.callout)
            Spacer()
            Menu {
                ForEach(WidgetKind.allCases) { k in
                    Button { add(k) } label: { Label(k.title, systemImage: k.icon) }
                }
            } label: { Label("Добавить виджет", systemImage: "plus") }
            .fixedSize()
            Button("Сбросить") { ThemeStore.animate { layouts.reset(key) } }
            Button("Готово") { ThemeStore.animate { editing = false } }.buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: theme.density.radius).fill(theme.accent.opacity(0.1)))
    }

    @ViewBuilder func widget(_ w: WidgetConfig) -> some View {
        let isTarget = dropTarget == w.id && dragging != w.id
        WidgetFrame(kind: w.kind, editing: editing) {
            WidgetContent(kind: w.kind, projectId: projectId)
        } controls: {
            HStack(spacing: 4) {
                Button { toggleWide(w) } label: {
                    Image(systemName: w.wide ? "rectangle.split.2x1" : "rectangle")
                }.help(w.wide ? "Половина ширины" : "На всю ширину")
                Button { remove(w) } label: { Image(systemName: "xmark") }.help("Скрыть виджет")
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .opacity(dragging == w.id ? 0.4 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: theme.density.radius + 2)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: isTarget ? 3 : 0, dash: [6, 4]))
        )
        .scaleEffect(isTarget ? 0.98 : 1)
        .onDrag {
            dragging = w.id
            return NSItemProvider(object: w.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: WidgetDrop(target: w, key: key, dragging: $dragging, dropTarget: $dropTarget))
    }

    func toggleWide(_ w: WidgetConfig) {
        var l = items
        if let i = l.firstIndex(of: w) { l[i].wide.toggle() }
        ThemeStore.animate { layouts.set(key, l) }
    }
    func remove(_ w: WidgetConfig) {
        ThemeStore.animate { layouts.set(key, items.filter { $0.id != w.id }) }
    }
    func add(_ k: WidgetKind) {
        ThemeStore.animate { layouts.set(key, items + [WidgetConfig(kind: k, wide: k.defaultWide)]) }
        editing = true
    }
}

/// Live reordering while dragging over another widget.
struct WidgetDrop: DropDelegate {
    let target: WidgetConfig
    let key: String
    @Binding var dragging: UUID?
    @Binding var dropTarget: UUID?

    func dropEntered(info: DropInfo) {
        dropTarget = target.id
        guard let from = dragging, from != target.id else { return }
        var l = LayoutStore.shared.layout(key)
        guard let fi = l.firstIndex(where: { $0.id == from }), let ti = l.firstIndex(where: { $0.id == target.id }) else { return }
        let item = l.remove(at: fi)
        l.insert(item, at: ti)
        ThemeStore.animate { LayoutStore.shared.set(key, l) }
    }
    func dropExited(info: DropInfo) { if dropTarget == target.id { dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        dropTarget = nil
        return true
    }
}

struct WidgetFrame<Content: View, Controls: View>: View {
    let kind: WidgetKind
    let editing: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var controls: Controls
    @ObservedObject private var theme = ThemeStore.shared
    @State private var wiggle = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.density.spacing - 2) {
            HStack(spacing: 6) {
                if editing {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("Потяните, чтобы переместить")
                }
                Image(systemName: kind.icon).foregroundStyle(theme.accent)
                Text(kind.title).font(.headline)
                Spacer()
                if editing { controls.transition(.opacity) }
            }
            content
                .allowsHitTesting(!editing)
        }
        .padding(theme.density.padding + 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SurfaceBackground(radius: theme.density.radius + 2))
        .rotationEffect(.degrees(editing && theme.animations ? (wiggle ? 0.25 : -0.25) : 0))
        .onChange(of: editing) { startWiggle() }
        .onAppear { startWiggle() }
    }

    func startWiggle() {
        guard editing, theme.animations else { wiggle = false; return }
        withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true)) { wiggle.toggle() }
    }
}

/// Surface honoring the selected card style.
struct SurfaceBackground: View {
    var radius: CGFloat
    var tint: Color = .clear
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            switch theme.cardStyle {
            case .filled: shape.fill(theme.surface)
            case .outlined: shape.fill(theme.surface.opacity(0.25))
            case .glass: shape.fill(.ultraThinMaterial)
            }
            shape.stroke(tint == .clear ? theme.border : tint.opacity(0.6), lineWidth: theme.cardStyle == .outlined ? 1.2 : 1)
        }
    }
}

// MARK: - Widget contents

struct WidgetContent: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var theme = ThemeStore.shared
    let kind: WidgetKind
    let projectId: String?

    var body: some View {
        switch kind {
        case .stats: stats
        case .approvals: approvals
        case .agents: AgentsGrid(projectId: projectId, showProject: projectId == nil)
        case .feed: FeedList(projectId: projectId, limit: 40, showComposer: projectId != nil).frame(maxHeight: 520)
        case .tasks: tasks
        case .commits: commits
        case .clients: clients
        case .hotFiles: hotFiles
        case .summary: summary
        }
    }

    var dayStart: Double { Calendar.current.startOfDay(for: store.now).timeIntervalSince1970 }

    var stats: some View {
        let active = store.activeAgents(in: projectId)
        let waiting = active.filter { store.status($0) == .waiting }.count + store.pending.filter { projectId == nil || $0.projectId == projectId }.count
        let commits = projectId.map { store.git[$0]?.todayCommits.count ?? 0 } ?? store.git.values.reduce(0) { $0 + $1.todayCommits.count }
        let done = store.tasks.filter { (projectId == nil || $0.projectId == projectId) && ($0.doneAt ?? 0) >= dayStart }.count
        let actions = store.events.filter { (projectId == nil || $0.projectId == projectId) && $0.createdAt >= dayStart && $0.kind == "action" }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: theme.density.spacing)], spacing: theme.density.spacing) {
            StatTile(title: "Агентов работает", value: active.count, icon: "person.2.wave.2", color: .green)
            StatTile(title: "Ждут вас", value: waiting, icon: "hand.raised", color: .orange)
            StatTile(title: "Коммитов сегодня", value: commits, icon: "checkmark.seal", color: .purple)
            StatTile(title: "Задач закрыто", value: done, icon: "checklist.checked", color: .blue)
            StatTile(title: "Действий сегодня", value: actions, icon: "terminal", color: theme.accent)
        }
    }

    @ViewBuilder var approvals: some View {
        let list = store.pending.filter { projectId == nil || $0.projectId == projectId }
        if list.isEmpty {
            Text("Нет коммитов, ожидающих одобрения").foregroundStyle(.secondary).font(.callout)
        } else {
            VStack(spacing: 10) { ForEach(list) { ApprovalRow(item: $0) } }
        }
    }

    @ViewBuilder var tasks: some View {
        let list = store.tasks.filter { (projectId == nil || $0.projectId == projectId) && ($0.status == .in_progress || $0.status == .review) }
        if list.isEmpty {
            Text("Нет задач в работе").foregroundStyle(.secondary).font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list.prefix(12)) { t in
                    HStack(spacing: 8) {
                        Circle().fill(t.status.color).frame(width: 7, height: 7)
                        Text("#\(t.id)").foregroundStyle(.secondary).font(.caption.monospacedDigit())
                        Text(t.title).lineLimit(1)
                        Spacer()
                        if !t.client.isEmpty { Pill(text: t.client, color: theme.accent) }
                        if let a = store.agent(t.assignee) { Pill(text: a.name, color: .green, icon: a.toolIcon) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
    }

    @ViewBuilder var commits: some View {
        let pairs: [(Project, CommitLine)] = store.projects
            .filter { projectId == nil || $0.id == projectId }
            .flatMap { p in (store.git[p.id]?.todayCommits ?? []).map { (p, $0) } }
        if pairs.isEmpty {
            Text("Сегодня коммитов не было").foregroundStyle(.secondary).font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pairs.prefix(14), id: \.1.hash) { p, c in
                    let agent = store.events.first { $0.kind == "commit" && $0.ref.hasPrefix(c.hash) }?.agentId
                    HStack(spacing: 8) {
                        Text(c.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(c.hash).font(.caption.monospaced()).foregroundStyle(.purple)
                        Text(c.subject).lineLimit(1)
                        Spacer()
                        if projectId == nil { Text(p.name).font(.caption).foregroundStyle(.secondary) }
                        if let n = store.agentName(agent) { Pill(text: n, color: .green) }
                    }
                }.feedRowTransition()
            }
        }
    }

    @ViewBuilder var clients: some View {
        let today = store.events.filter { $0.createdAt >= dayStart && !$0.client.isEmpty && (projectId == nil || $0.projectId == projectId) }
        let tasksToday = store.tasks.filter { $0.updatedAt >= dayStart && !$0.client.isEmpty && (projectId == nil || $0.projectId == projectId) }
        let names = Set(today.map(\.client) + tasksToday.map(\.client)).sorted()
        if names.isEmpty {
            Text("Сегодня работы по клиентам не отмечено. Указывайте клиента в задачах.").foregroundStyle(.secondary).font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { c in
                    let t = tasksToday.filter { $0.client == c }
                    HStack {
                        Pill(text: c, color: theme.accent, icon: "person.crop.square")
                        Text("\(t.filter { $0.status == .done }.count) готово · \(t.filter { $0.status != .done }.count) в работе · \(today.filter { $0.client == c }.count) событий")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }.feedRowTransition()
            }
        }
    }

    @ViewBuilder var hotFiles: some View {
        let files = store.files.filter { (projectId == nil || $0.projectId == projectId) && $0.lastAt >= dayStart }
        let grouped = Dictionary(grouping: files, by: \.path)
            .map { (path: $0.key, agents: Set($0.value.map(\.agentId)), count: $0.value.reduce(0) { $0 + $1.count }) }
            .sorted { ($0.agents.count, $0.count) > ($1.agents.count, $1.count) }
        if grouped.isEmpty {
            Text("Сегодня файлы не менялись").foregroundStyle(.secondary).font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(grouped.prefix(12), id: \.path) { f in
                    HStack(spacing: 8) {
                        Image(systemName: f.agents.count > 1 ? "exclamationmark.triangle.fill" : "doc")
                            .foregroundStyle(f.agents.count > 1 ? .orange : .secondary)
                        Text(f.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(f.agents.compactMap { store.agentName($0) }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        Text("×\(f.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).smoothNumber(f.count, Double(f.count))
                    }
                }.feedRowTransition()
            }
        }
    }

    @ViewBuilder var summary: some View {
        if let s = store.summaries.first {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.day).font(.caption).foregroundStyle(.secondary)
                MarkdownView(text: String(s.markdown.prefix(1400))).frame(maxHeight: 260, alignment: .top).clipped()
            }
        } else {
            HStack {
                Text("Сводок пока нет").foregroundStyle(.secondary)
                Spacer()
                Button("Сводка за сегодня") { store.generateSummary(day: Date()) }
            }
        }
    }
}
