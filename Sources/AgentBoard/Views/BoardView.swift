import SwiftUI

struct BoardView: View {
    @EnvironmentObject var store: Store
    let projectId: String
    @State private var clientFilter = ""
    @State private var editing: TaskItem?
    @State private var creating = false

    func items(_ st: TaskStatus) -> [TaskItem] {
        store.tasks(in: projectId)
            .filter { $0.status == st && (clientFilter.isEmpty || $0.client == clientFilter) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Клиент", selection: $clientFilter) {
                    Text("Все клиенты").tag("")
                    ForEach(store.clients(in: projectId), id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 260)
                Spacer()
                Text("Перетаскивайте карточки между колонками").font(.caption).foregroundStyle(.secondary)
                Button { creating = true } label: { Label("Новая задача", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.top, 14)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(TaskStatus.allCases) { st in column(st) }
                }
                .padding(20)
            }
        }
        .sheet(item: $editing) { t in TaskEditor(projectId: projectId, original: t) }
        .sheet(isPresented: $creating) { TaskEditor(projectId: projectId, original: nil) }
    }

    func column(_ st: TaskStatus) -> some View {
        let list = items(st)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(st.color).frame(width: 8, height: 8)
                Text(st.label).font(.headline)
                Text("\(list.count)").foregroundStyle(.secondary).smoothNumber(list.count, Double(list.count))
                Spacer()
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(list) { t in
                        TaskCard(task: t)
                            .onTapGesture { editing = t }
                            .draggable(String(t.id))
                            .contextMenu {
                                ForEach(TaskStatus.allCases.filter { $0 != st }) { s in
                                    Button("→ \(s.label)") { store.moveTask(t.id, to: s) }
                                }
                                Divider()
                                Button("Запустить агента / рабочая копия…") { editing = t }
                                Divider()
                                Button("Удалить", role: .destructive) { store.deleteTask(t.id) }
                            }
                    }.feedRowTransition()
                    .animateRows(list.map(\.id))
                }
            }
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .dropDestination(for: String.self) { ids, _ in
            for s in ids { if let id = Int64(s) { store.moveTask(id, to: st) } }
            return true
        }
    }
}

struct TaskCard: View {
    @EnvironmentObject var store: Store
    let task: TaskItem
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text("#\(task.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(task.title).font(.callout.weight(.medium)).lineLimit(3)
                }
                if !task.details.isEmpty {
                    Text(task.details).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 6) {
                    if !task.client.isEmpty { Pill(text: task.client, color: .accentColor, icon: "person.crop.square") }
                    if !task.branch.isEmpty { Pill(text: task.branch, color: .purple, icon: "arrow.triangle.branch") }
                    if let a = store.agent(task.assignee) {
                        let st = store.status(a)
                        Pill(text: a.name, color: st == .working || st == .waiting ? .green : .secondary, icon: a.toolIcon)
                    }
                    Spacer()
                    Text(Fmt.rel(task.updatedAt, now: store.now)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TaskEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let projectId: String
    let original: TaskItem?
    @State private var title = ""
    @State private var details = ""
    @State private var client = ""
    @State private var status: TaskStatus = .backlog
    @State private var assignee: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "Новая задача" : "Задача #\(original!.id)").font(.title3.bold())
            Form {
                TextField("Название", text: $title)
                TextField("Клиент", text: $client)
                if !store.clients(in: nil).isEmpty {
                    HStack {
                        ForEach(store.clients(in: nil).prefix(6), id: \.self) { c in
                            Button(c) { client = c }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                Picker("Статус", selection: $status) {
                    ForEach(TaskStatus.allCases) { Text($0.label).tag($0) }
                }
                Picker("Исполнитель", selection: $assignee) {
                    Text("—").tag("")
                    ForEach(store.agents(in: projectId).filter { $0.status != "ended" || $0.id == assignee }) { a in
                        Text("\(a.name) (\(a.toolLabel))").tag(a.id)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Описание").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $details).frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                }
            }
            if let original {
                Divider()
                TaskWorkspaceSection(taskId: original.id)
                Divider()
            }
            HStack {
                if let original {
                    Button("Удалить", role: .destructive) { store.deleteTask(original.id); dismiss() }
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onAppear {
            if let t = original {
                title = t.title; details = t.details; client = t.client; status = t.status; assignee = t.assignee ?? ""
            } else {
                client = store.project(projectId)?.client ?? ""
            }
        }
    }

    func save() {
        let who: String? = assignee.isEmpty ? nil : assignee
        if var t = original {
            t.title = title.trimmed; t.details = details; t.client = client.trimmed; t.status = status; t.assignee = who
            store.saveTask(t)
        } else {
            store.createTask(project: projectId, title: title.trimmed, details: details, client: client.trimmed, status: status, assignee: who)
        }
        dismiss()
    }
}
