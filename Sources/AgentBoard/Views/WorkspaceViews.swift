import AppKit
import SwiftUI

/// Inside the task editor: start an agent on the task (optionally in its own worktree) and manage that worktree.
struct TaskWorkspaceSection: View {
    @EnvironmentObject var store: Store
    let taskId: Int64
    @AppStorage("launch.tool") private var tool = "claude"
    @AppStorage("launch.isolated") private var isolated = true
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?
    @State private var reviewing = false
    @State private var confirmRemove = false
    @State private var confirmMerge = false

    var task: TaskItem? { store.tasks.first { $0.id == taskId } }

    var body: some View {
        if let t = task, let p = store.project(t.projectId) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Агент и рабочая копия").font(.headline)
                let worker = store.agent(t.assignee)
                if let worker, worker.isActive(staleMinutes: store.staleMinutes, at: store.now) {
                    HStack {
                        StatusBadge(status: store.status(worker))
                        Text("Работает \(worker.name) (\(worker.toolLabel))").font(.callout)
                    }
                } else {
                    HStack(spacing: 10) {
                        Picker("", selection: $tool) {
                            Text("Claude Code").tag("claude")
                            Text("Codex").tag("codex")
                        }
                        .labelsHidden().frame(width: 150)
                        Toggle("В отдельном worktree", isOn: $isolated).toggleStyle(.checkbox)
                            .help("Своя ветка agent/<номер>-<название> и своя папка: агент не мешает другим и вашей рабочей копии")
                        Spacer()
                        Button {
                            run { try Workspaces.launch(task: t, project: p, tool: tool, isolated: isolated) }
                        } label: { Label("Запустить агента", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    }
                    Text("Откроется \(AppSettings.terminalApp == "iTerm" ? "iTerm2" : "Terminal") с агентом; задача станет его, как только он подключится.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !t.branch.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow { Text("Ветка").foregroundStyle(.secondary); Text("\(t.branch) ← \(t.baseBranch)").textSelection(.enabled) }
                        if !t.worktree.isEmpty {
                            GridRow {
                                Text("Папка").foregroundStyle(.secondary)
                                Text(t.worktree).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                    HStack {
                        Button { reviewing = true } label: { Label("Изменения и ревью", systemImage: "doc.text.magnifyingglass") }
                            .buttonStyle(.borderedProminent)
                        if !t.worktree.isEmpty {
                            Button { revealInFinder(t.worktree) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                            Button { run { try Workspaces.openTerminal("cd \(Workspaces.shq(t.worktree))"); return nil } } label: {
                                Image(systemName: "terminal")
                            }.help("Открыть терминал в рабочей копии")
                        }
                        Spacer()
                        Button("Слить в \(t.baseBranch)") { confirmMerge = true }.disabled(busy)
                        Button("Создать PR") { run { try Workspaces.createPR(task: t, project: p) } }.disabled(busy)
                        if !t.worktree.isEmpty {
                            Button("Убрать worktree", role: .destructive) { confirmRemove = true }.disabled(busy)
                        }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                if let result { Text(result).font(.caption).foregroundStyle(.green).textSelection(.enabled) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .sheet(isPresented: $reviewing) { ReviewSheet(taskId: taskId) }
            .confirmationDialog("Слить \(t.branch) в \(t.baseBranch) в \(p.path)?", isPresented: $confirmMerge) {
                Button("Слить") {
                    run {
                        let r = try Workspaces.merge(task: t, project: p)
                        store.moveTask(t.id, to: .done)
                        return r
                    }
                }
            } message: { Text("Будет сделан merge --no-ff в основной рабочей копии. При конфликте слияние отменится.") }
            .confirmationDialog("Убрать рабочую копию \(t.worktree)?", isPresented: $confirmRemove) {
                Button("Убрать", role: .destructive) { run { try Workspaces.removeWorktree(task: t, project: p); return "Рабочая копия убрана, ветка \(t.branch) осталась." } }
            } message: { Text("Папка удаляется через git worktree remove; ветка с коммитами остаётся. Если там есть незакоммиченные изменения, git откажет.") }
        }
    }

    func run(_ work: @escaping () throws -> String?) {
        busy = true; result = nil; error = nil
        store.workspace(work) { ok, err in
            busy = false
            result = ok
            error = err
        }
    }
}

/// Review of a task branch: per-file diff, comments on lines, sent back to the agent's session.
struct ReviewSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let taskId: Int64

    struct Comment: Identifiable, Hashable {
        var id = UUID()
        var file: String
        var line: Int?
        var code: String
        var text: String
    }

    @State private var files: [DiffFile] = []
    @State private var commits: [String] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var comments: [Comment] = []
    @State private var editing: (file: String, line: DiffLine)?
    @State private var draft = ""
    @State private var general = ""
    @State private var mode: DeliveryMode = .auto
    @State private var sendResult: String?

    var task: TaskItem? { store.tasks.first { $0.id == taskId } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Изменений пока нет").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    fileList.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    diffView.frame(minWidth: 560)
                }
            }
            Divider()
            footer
        }
        .frame(width: 1180, height: 780)
        .onAppear(perform: load)
    }

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ревью · #\(taskId) \(task?.title ?? "")").font(.title3.bold()).lineLimit(1)
                if let t = task {
                    Text("\(t.branch) ← \(t.baseBranch) · коммитов: \(commits.count) · файлов: \(files.count) · "
                         + "+\(files.map(\.added).reduce(0, +)) −\(files.map(\.removed).reduce(0, +))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
            Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    var fileList: some View {
        List(selection: $selected) {
            if !commits.isEmpty {
                Section("Коммиты") {
                    ForEach(commits, id: \.self) { Text($0).font(.caption.monospaced()).lineLimit(1) }
                }
            }
            Section("Файлы") {
                ForEach(files) { f in
                    HStack {
                        Text(f.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                        Spacer()
                        let n = comments.filter { $0.file == f.path }.count
                        if n > 0 { Pill(text: "\(n)", color: .orange, icon: "text.bubble") }
                        Text("+\(f.added)").font(.caption2).foregroundStyle(.green)
                        Text("−\(f.removed)").font(.caption2).foregroundStyle(.red)
                    }
                    .tag(f.path)
                }
            }
        }
    }

    var diffView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { f in
                        Text(f.path).font(.callout.monospaced().weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                            .id(f.path)
                        ForEach(f.lines) { l in line(f, l) }
                    }
                }
                .textSelection(.enabled)
            }
            .onChange(of: selected) { if let s = selected { withAnimation { proxy.scrollTo(s, anchor: .top) } } }
        }
    }

    @ViewBuilder func line(_ f: DiffFile, _ l: DiffLine) -> some View {
        let bg: Color = l.kind == .add ? .green.opacity(0.13) : l.kind == .del ? .red.opacity(0.13) : l.kind == .hunk ? .blue.opacity(0.08) : .clear
        HStack(alignment: .top, spacing: 0) {
            Text(l.oldNo.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
            Text(l.newNo.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
            Text(l.kind == .add ? " + " : l.kind == .del ? " − " : "   ").foregroundStyle(l.kind == .add ? .green : .red)
            Text(l.text.isEmpty ? " " : l.text).foregroundStyle(l.kind == .hunk ? .blue : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if l.kind != .hunk {
                Button { editing = (f.path, l); draft = "" } label: { Image(systemName: "plus.bubble") }
                    .buttonStyle(.borderless).help("Комментарий к строке").padding(.trailing, 6)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(bg)
        ForEach(comments.filter { $0.file == f.path && $0.code == l.text && $0.line == (l.newNo ?? l.oldNo) }) { c in
            HStack(alignment: .top) {
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
                Text(c.text).font(.callout)
                Spacer()
                Button { comments.removeAll { $0.id == c.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            .padding(8).padding(.leading, 90)
            .background(Color.orange.opacity(0.08))
        }
        if let e = editing, e.file == f.path, e.line.id == l.id {
            HStack {
                TextField("Что не так / что поменять", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addComment)
                Button("Добавить", action: addComment).disabled(draft.trimmed.isEmpty)
                Button("Отмена") { editing = nil }
            }
            .padding(8).padding(.leading, 90)
            .background(Color.orange.opacity(0.06))
        }
    }

    func addComment() {
        guard let e = editing, !draft.trimmed.isEmpty else { return }
        comments.append(Comment(file: e.file, line: e.line.newNo ?? e.line.oldNo, code: e.line.text, text: draft.trimmed))
        editing = nil
        draft = ""
    }

    var footer: some View {
        let t = task
        let agent = store.agent(t?.assignee)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Общий комментарий к работе", text: $general, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                if let agent {
                    Text("Агенту \(agent.name)").font(.callout)
                    Picker("", selection: $mode) { ForEach(DeliveryMode.allCases) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 260)
                } else {
                    Text("У задачи нет исполнителя — запустите агента, чтобы отправить ему ревью").font(.caption).foregroundStyle(.secondary)
                }
                if let sendResult { Text(sendResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Принять → Готово") {
                    store.moveTask(taskId, to: .done)
                    dismiss()
                }
                Button {
                    send(to: agent)
                } label: { Label("Отправить на доработку (\(comments.count + (general.trimmed.isEmpty ? 0 : 1)))", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(agent == nil || (comments.isEmpty && general.trimmed.isEmpty))
            }
        }
        .padding(14)
    }

    func send(to agent: Agent?) {
        guard let agent else { return }
        var lines = ["Ревью задачи #\(taskId) — поправь, пожалуйста:"]
        for c in comments {
            let code = c.code.trimmed.isEmpty ? "" : "  (`\(c.code.trimmed.trunc(120))`)"
            lines.append("- \(c.file)\(c.line.map { ":\($0)" } ?? "")\(code) — \(c.text)")
        }
        if !general.trimmed.isEmpty { lines.append("Общее: \(general.trimmed)") }
        lines.append("Когда исправишь — закоммить и снова update_task(task_id: \(taskId), status: \"review\").")
        store.moveTask(taskId, to: .in_progress)
        SessionDelivery.deliver(agentId: agent.id, text: lines.joined(separator: "\n"), mode: mode) { r in
            sendResult = r
            comments = []
            general = ""
        }
    }

    func load() {
        guard let t = task, let p = store.project(t.projectId) else { loading = false; return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let d = DiffParser.parse(Workspaces.diff(task: t, project: p))
            let c = Workspaces.commits(task: t, project: p)
            DispatchQueue.main.async {
                files = d
                commits = c
                loading = false
                if selected == nil { selected = d.first?.path }
            }
        }
    }
}
