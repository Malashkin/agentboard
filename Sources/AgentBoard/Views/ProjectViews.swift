import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var theme = ThemeStore.shared
    @Binding var selection: NavItem?
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.density.spacing + 6) {
                HStack {
                    Text("Overview").font(.largeTitle.bold())
                    Spacer()
                    if !store.projects.isEmpty && !editing {
                        Button { ThemeStore.animate { editing = true } } label: { Label("Customize dashboard", systemImage: "square.grid.3x3.square") }
                    }
                }
                if store.projects.isEmpty {
                    Onboarding(selection: $selection)
                } else {
                    Dashboard(key: "overview", projectId: nil, editing: $editing)
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
                Text("Getting started").font(.title2.bold())
                Label("Open Integrations and connect Claude Code (hooks + MCP) and, if you use it, Codex.", systemImage: "1.circle.fill")
                Label("Add a project: the git repository folder your agents work in (button at the bottom left).", systemImage: "2.circle.fill")
                Label("Run Claude Code in separate terminals in that folder or its worktrees. Agents will show up here and see each other.", systemImage: "3.circle.fill")
                Label("In the evening, AgentBoard compiles a summary of what was done, by code and by client.", systemImage: "4.circle.fill")
                Button("Open Integrations") { selection = .integrations }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ProjectView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var theme = ThemeStore.shared
    let projectId: String
    @AppStorage("projectTab") private var tab = 0
    @State private var editing = false

    var body: some View {
        if let p = store.project(projectId) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.name).font(.title.bold())
                            if !p.client.isEmpty { Pill(text: p.client, color: theme.accent, icon: "person.crop.square") }
                        }
                        Text(p.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if tab == 0 && !editing {
                        Button { ThemeStore.animate { editing = true } } label: { Label("Customize", systemImage: "square.grid.3x3.square") }
                    }
                    Picker("", selection: Binding(get: { tab }, set: { v in ThemeStore.animate { tab = v } })) {
                        Text("Dashboard").tag(0)
                        Text("Agents").tag(1)
                        Text("Tasks").tag(2)
                        Text("Feed").tag(3)
                        Text("Git").tag(4)
                        Text("Memory").tag(6)
                        Text("Settings").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 580)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
                Group {
                    switch tab {
                    case 0: ScrollView { Dashboard(key: "project:" + p.id, projectId: p.id, editing: $editing).padding(20) }
                    case 1: ScrollView { AgentsGrid(projectId: p.id).padding(20) }
                    case 2: BoardView(projectId: p.id)
                    case 3: ScrollView { FeedList(projectId: p.id, limit: 500, showComposer: true).padding(20) }
                    case 4: GitView(projectId: p.id)
                    case 6: MemoryView(project: p)
                    default: ProjectSettingsView(project: p)
                    }
                }
                .transition(.opacity)
            }
        } else {
            Text("Project not found").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Feed

struct FeedList: View {
    @EnvironmentObject var store: Store
    let projectId: String?
    var limit = 200
    var showComposer = false
    /// Long lists (the Feed tab) render lazily; short dashboard lists don't, which keeps row animations reliable.
    var lazy = true
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
                    TextField("Post a note to the feed (agents see it via board)…", text: $note).textFieldStyle(.roundedBorder)
                        .onSubmit { post(projectId) }
                    Button("Add") { post(projectId) }.disabled(note.trimmed.isEmpty)
                }
            }
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("All activity (requests, commands, edits)", isOn: $showRoutine).toggleStyle(.checkbox)
                Spacer()
            }
            if items.isEmpty {
                Text("No events yet").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) { rows }
            } else {
                VStack(alignment: .leading, spacing: 0) { rows }
                    .animateRows(items.map(\.id))
            }
        }
    }

    @ViewBuilder var rows: some View {
        ForEach(items) { e in
            VStack(spacing: 0) { row(e); Divider() }
                .feedRowTransition()
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
                    Text("Worktrees").font(.title2.bold())
                    Spacer()
                    Button { GitMonitor.shared.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                ForEach(snap.worktrees) { w in
                    let owner = store.agents(in: projectId).first { $0.isActive(staleMinutes: store.staleMinutes, at: store.now) && ($0.root == w.path || $0.cwd.hasPrefix(w.path)) }
                    Card(tint: w.changes.isEmpty ? .clear : .orange) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Pill(text: w.branch, color: .purple, icon: "arrow.triangle.branch")
                                if w.ahead > 0 { Pill(text: "↑\(w.ahead) not pushed", color: .blue) }
                                if w.behind > 0 { Pill(text: "↓\(w.behind)", color: .gray) }
                                if let owner { Pill(text: owner.name, color: .green, icon: "person") }
                                Spacer()
                                Text(w.changes.isEmpty ? "clean" : "\(w.changes.count) uncommitted").smoothNumber(w.changes.count)
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
                Text("Today's commits").font(.title2.bold())
                if snap.todayCommits.isEmpty { Text("None yet").foregroundStyle(.secondary) }
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
                }.feedRowTransition()
                .animateRows(snap.todayCommits.map(\.id))
            }
            .padding(20)
        }
    }
}

// MARK: - Project settings

/// Project memory: lasting facts every new session gets at its start (see ProjectMemory.swift).
struct MemoryView: View {
    @EnvironmentObject var store: Store
    let project: Project
    @State private var draft = ""

    var body: some View {
        let items = store.memory(of: project.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What every new agent session in \(project.name) is told at its start. Agents add facts with remember(); you can add, and remove anything that's wrong.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("A fact every session should know — e.g. “Run tests with ./scripts/test.sh, never npm test”", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(draft.trimmed.isEmpty)
                }
                if items.isEmpty {
                    Text("Nothing yet. Agents save what they learn here, so the next session doesn't have to find it out again.")
                        .foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(items) { m in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: m.byHuman ? "person.fill" : "sparkle").foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.text).textSelection(.enabled)
                            Text("#\(m.id) · " + (m.byHuman ? "you" : m.author) + " · " + Fmt.rel(m.createdAt, now: store.now))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.forget(m) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove from project memory")
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                }
            }
            .padding(20)
        }
    }

    func add() {
        let t = draft.trimmed
        guard !t.isEmpty else { return }
        draft = ""
        store.remember(project: project.id, text: t)
    }
}

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
            Section("Project") {
                TextField("Name", text: $name)
                Text("Shown in AgentBoard only; the folder keeps its name. Empty → folder name.").font(.caption).foregroundStyle(.secondary)
                TextField("Default client", text: $client)
                Text("The client is prefilled in new tasks and helps group the summary by client.").font(.caption).foregroundStyle(.secondary)
                Button("Save") { store.updateProject(project.id, name: name, client: client) }
            }
            Section("Project integration") {
                LabeledContent("git post-commit hook") {
                    HStack {
                        Text(gitHook ? "installed" : "not installed").foregroundStyle(gitHook ? .green : .orange)
                        Button(gitHook ? "Remove" : "Install") {
                            if gitHook { Integrations.uninstallGitHook(project) } else {
                                do { try Integrations.installGitHook(project) } catch { message = error.localizedDescription }
                            }
                            refresh()
                        }
                    }
                }
                Text("Captures commits from any agent (including Codex) across all of the project's worktrees.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Rules in AGENTS.md") {
                    HStack {
                        Text(agentsMd ? "added" : "not added").foregroundStyle(agentsMd ? .green : .secondary)
                        if !agentsMd {
                            Button("Add") {
                                do { try Integrations.installAgentsMd(project) } catch { message = error.localizedDescription }
                                refresh()
                            }
                        }
                    }
                }
                Text("Needed for Codex and other agents without hooks: it explains how to use the board. Claude Code gets the rules automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                LabeledContent("Past sessions and commits") {
                    if store.importing.contains(project.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Import") { store.importHistory(project) }
                    }
                }
                Text(store.importReport[project.id] ?? "Claude Code and Codex sessions and commits from the last 60 days, made before the project was connected. Re-importing does not create duplicates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agents") {
                Button("Clear finished and inactive agents") { store.purgeAgents(project: project.id) }
            }
            Section {
                Button("Remove project from AgentBoard", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = project.name; client = project.client; refresh() }
        .confirmationDialog("Remove “\(project.name)” from AgentBoard?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove, keep its history") {
                Integrations.uninstallGitHook(project)
                store.archiveProject(project.id)
            }
            Button("Remove and delete its history", role: .destructive) {
                Integrations.uninstallGitHook(project)
                store.removeProject(project.id)
            }
        } message: { Text("Project files are not touched. Keep history: adding the same folder again brings back its tasks, feed and notes.") }
        .alert("Error", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func refresh() {
        gitHook = Integrations.gitHookInstalled(project)
        agentsMd = Integrations.agentsMdInstalled(project)
    }
}
