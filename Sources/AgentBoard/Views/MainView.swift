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
    @State private var renaming: Project?
    @State private var newName = ""
    @State private var removing: Project?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Overview", systemImage: "square.grid.2x2").tag(NavItem.overview)
                    Label("History", systemImage: "calendar").tag(NavItem.history)
                    Label("Summaries", systemImage: "doc.richtext").tag(NavItem.summaries)
                    Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted").tag(NavItem.integrations)
                }
                Section("Projects") {
                    ForEach(store.orderedProjects) { p in
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name)
                                    if store.importing.contains(p.id) {
                                        Text("Loading history…").font(.caption2).foregroundStyle(.secondary)
                                    } else if let t = store.lastWork[p.id] {
                                        Text(Self.lastWorkLabel(t, now: store.now)).font(.caption2).foregroundStyle(.secondary)
                                            .help("Last agent activity: " + Fmt.dayHuman.string(from: Date(timeIntervalSince1970: t)) + ", " + Fmt.time(t))
                                    }
                                }
                            } icon: { Image(systemName: "folder") }
                            Spacer()
                            let active = store.activeAgents(in: p.id)
                            let waiting = active.filter { store.status($0) == .waiting }.count
                            if waiting > 0 {
                                Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.caption)
                            }
                            if !active.isEmpty {
                                Text("\(active.count)").font(.caption.monospacedDigit()).smoothNumber(active.count, Double(active.count))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                            }
                        }
                        .tag(NavItem.project(p.id))
                        .contextMenu {
                            Button("Rename…") { newName = p.name; renaming = p }
                            Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                            Divider()
                            Button("Remove from AgentBoard…", role: .destructive) { removing = p }
                        }
                    }
                    .onMove { store.moveProjects(from: $0, to: $1) }
                }
                if !store.suggestions.isEmpty || store.ignoredCount > 0 {
                    Section {
                        ForEach(store.suggestions) { c in
                            SuggestionRow(candidate: c, live: store.liveSuggestion?.path == c.path) { add(c) }
                        }
                    } header: {
                        HStack {
                            Text("Suggested")
                                .help("Folders where Claude Code or Codex worked in the last 60 days that aren't on the board")
                            Spacer()
                            if store.ignoredCount > 0 {
                                Button("\(store.ignoredCount) ignored · show") { store.clearIgnoredSuggestions() }
                                    .buttonStyle(.hover).font(.caption2)
                                    .help("Suggest the folders you ignored again")
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let p = renaming { store.renameProject(p.id, newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Only how it's called in AgentBoard — the folder isn't renamed. Leave empty to use the folder name (\(renaming.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "")).")
            }
            .confirmationDialog("Remove “\(removing?.name ?? "")” from AgentBoard?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove, keep its history") {
                    if let p = removing { removeProject(p, keepHistory: true) }
                }
                Button("Remove and delete its history", role: .destructive) {
                    if let p = removing { removeProject(p, keepHistory: false) }
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("The project disappears from the sidebar and AgentBoard stops tracking it. Project files are not touched.\n\nKeep history: add the same folder again later and its tasks, feed, notes and time come back.\nDelete: everything recorded is erased; re-adding imports only what Claude Code / Codex still keep (last 60 days) and git commits.")
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { addProject() } label: { Label("Add project", systemImage: "plus") }
                        .buttonStyle(.hover)
                    Spacer()
                    Circle().fill(store.serverRunning ? Color.green : Color.red).frame(width: 7, height: 7)
                        .help(store.serverRunning ? "Server running on 127.0.0.1:\(AppSettings.port)" : "Server not running")
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
                if store.hooksMissing && !store.agents.isEmpty {
                    ConnectHooksBanner().transition(.move(edge: .top).combined(with: .opacity))
                }
                if let c = store.liveSuggestion {
                    LiveFolderBanner(candidate: c) { add(c) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let d = store.awayDigest {
                    AwayBanner(digest: d).transition(.move(edge: .top).combined(with: .opacity))
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
            .animation(theme.anim(), value: store.liveSuggestion?.path)
            .animation(theme.anim(.easeInOut(duration: 0.2)), value: selection)
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .alert("Couldn’t add project", isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })) {
            Button("OK") { addError = nil }
        } message: { Text(addError ?? "") }
    }

    /// Dashboards show approvals as a widget, so the banner isn't duplicated there.
    var isDashboard: Bool {
        if case .overview = selection ?? .overview { return true }
        if case .project = selection, UserDefaults.standard.integer(forKey: "projectTab") == 0 { return true }
        return false
    }

    func removeProject(_ p: Project, keepHistory: Bool) {
        if case .project(let id) = selection ?? .overview, id == p.id { selection = .overview }
        DispatchQueue.global(qos: .utility).async { Integrations.uninstallGitHook(p) }
        if keepHistory { store.archiveProject(p.id) } else { store.removeProject(p.id) }
        removing = nil
    }

    static func lastWorkLabel(_ t: Double, now: Date) -> String {
        let d = Date(timeIntervalSince1970: t)
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return "today, " + f.string(from: d) }
        if cal.isDateInYesterday(d) { f.dateFormat = "HH:mm"; return "yesterday, " + f.string(from: d) }
        f.dateFormat = cal.isDate(d, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    func add(_ c: ProjectDiscovery.Candidate) {
        store.addSuggestion(c) { err in
            if let err { addError = err }
            else if let p = store.projects.first(where: { $0.path == c.path }) { selection = .project(p.id) }
        }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose the project folder (a git repository) your agents work in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addProject(path: url.path) { err in
            if let err { addError = err }
            else if let p = store.projects.last(where: { $0.path.hasSuffix(url.lastPathComponent) }) { selection = .project(p.id) }
        }
    }
}

/// A folder agents worked in that isn't on the board: one click adds it (history is imported as usual).
struct SuggestionRow: View {
    @EnvironmentObject var store: Store
    let candidate: ProjectDiscovery.Candidate
    let live: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name).foregroundStyle(.secondary)
                    Text(live ? "agent working now" : "\(candidate.sessions) session\(candidate.sessions == 1 ? "" : "s") · "
                         + MainView.lastWorkLabel(candidate.lastAt, now: store.now))
                        .font(.caption2).foregroundStyle(live ? Color.green : Color.secondary)
                }
            } icon: { Image(systemName: "folder.badge.plus").foregroundStyle(.secondary) }
            Spacer()
            Button { onAdd() } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.hover)
                .help("Add to the board")
            Button { store.ignoreSuggestion(candidate) } label: { Image(systemName: "xmark") }
                .buttonStyle(.hover).foregroundStyle(.secondary)
                .help("Ignore — don’t suggest this folder again")
        }
        .help("\(candidate.path)\n\(candidate.toolsLabel)\(candidate.isGit ? "" : " · not a git repository")")
        .contextMenu {
            Button("Add to AgentBoard") { onAdd() }
            Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)]) }
            Divider()
            Button("Ignore (don’t suggest again)") { store.ignoreSuggestion(candidate) }
        }
    }
}

struct LiveFolderBanner: View {
    @EnvironmentObject var store: Store
    let candidate: ProjectDiscovery.Candidate
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").foregroundStyle(Color.accentColor)
            Text("An agent is working in **\(candidate.name)**, which isn’t on the board.").lineLimit(2)
                .help(candidate.path)
            Spacer()
            Button("Add project") { onAdd() }.controlSize(.small)
            Button("Not now") { store.dismissedLive.insert(candidate.path) }
                .buttonStyle(.hover).controlSize(.small)
            Button("Ignore") { store.ignoreSuggestion(candidate) }
                .buttonStyle(.hover).controlSize(.small)
                .help("Don’t suggest this folder again")
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }
}

/// Sessions are on the board from their files, but Claude Code isn't connected: one click fixes it.
struct ConnectHooksBanner: View {
    @EnvironmentObject var store: Store
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Color.accentColor)
            Text(result ?? "Your open Claude Code sessions are shown from their session files. Connect Claude Code for live actions, decisions, replies and coordination.")
                .lineLimit(3)
            Spacer()
            if result == nil {
                Button(busy ? "Connecting…" : "Connect Claude Code") { connect() }.controlSize(.small).disabled(busy)
            } else {
                Button("OK") { store.hooksMissing = false }.buttonStyle(.hover).controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }

    func connect() {
        busy = true
        DispatchQueue.global().async {
            var err: String?
            do { try Integrations.installClaudeHooks(); try Integrations.installClaudeMCP() } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                busy = false
                result = err.map { "Couldn't connect: \($0)" }
                    ?? "Connected. Each open session reports live from its next prompt; restart a session if it doesn't."
            }
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
            if let onClose { Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.hover) }
        }
        .padding(10)
        .foregroundStyle(color)
        .background(color.opacity(0.1))
    }
}

struct AwayBanner: View {
    @EnvironmentObject var store: Store
    let digest: AwayDigest
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sunrise.fill").foregroundStyle(.orange)
                Text("While you were away · \(TimeReport.format(digest.to - digest.from))").font(.headline)
                if digest.commits > 0 { Pill(text: "\(digest.commits) commits", color: .purple, icon: "checkmark.seal") }
                if digest.questions > 0 { Pill(text: "\(digest.questions) waiting for you", color: .orange, icon: "hand.raised") }
                if digest.stuck > 0 { Pill(text: "\(digest.stuck) stuck", color: .red, icon: "arrow.triangle.2.circlepath") }
                if digest.writing { ProgressView().controlSize(.small) }
                Spacer()
                Button { withAnimation(ThemeStore.shared.anim()) { store.awayDigest = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hover)
            }
            Text(digest.text.isEmpty ? "Summarizing…" : digest.text).font(.callout).textSelection(.enabled)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
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
    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var icon: (String, Color) {
        switch item.kind {
        case "question": return ("questionmark.bubble.fill", .blue)
        case "plan": return ("list.bullet.clipboard.fill", .teal)
        case "permission": return ("lock.shield.fill", .orange)
        default: return ("arrow.up.doc.fill", .purple)
        }
    }

    var heading: String {
        switch item.kind {
        case "question": return "\(item.agentName) is asking · \(item.projectName)"
        case "plan": return "\(item.agentName) proposes a plan · \(item.projectName)"
        case "permission": return "\(item.agentName) needs permission · \(item.projectName)"
        default: return "\(item.agentName) wants to commit · \(item.projectName)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: icon.0).foregroundStyle(icon.1).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(heading).font(.headline)
                    if item.kind != "question" {
                        Text(item.command).font(.system(.caption, design: .monospaced)).lineLimit(compact ? 2 : 4)
                            .textSelection(.enabled)
                    }
                    let left = max(0, Int(item.deadline - store.now.timeIntervalSince1970))
                    Text(item.kind == "commit"
                         ? "No decision in \(left / 60):\(String(format: "%02d", left % 60)) and the question goes to the terminal"
                         : "The same question is open in the agent’s terminal. Answer there or here.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if item.kind == "question" {
                questions
            } else if item.kind == "plan" {
                if !compact {
                    ScrollView { MarkdownView(text: item.gitStatus) }
                        .frame(maxHeight: 260)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                HStack {
                    TextField("What should change in the plan", text: $comment).textFieldStyle(.roundedBorder)
                    Button("Request changes") { store.decide(item.id, allow: false, comment: comment) }
                        .disabled(comment.trimmed.isEmpty)
                    Button("Approve plan") { store.decide(item.id, allow: true, comment: "") }
                        .buttonStyle(.hoverProminent)
                }
            } else {
                if !compact && !item.gitStatus.isEmpty {
                    DisclosureGroup(item.kind == "commit" ? "Changes (git status)" : "Details", isExpanded: $showStatus) {
                        ScrollView {
                            Text(item.gitStatus)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }.frame(maxHeight: 200)
                    }.font(.caption)
                }
                HStack {
                    TextField("Comment for the agent (optional)", text: $comment).textFieldStyle(.roundedBorder)
                    Button("Deny", role: .destructive) { store.decide(item.id, allow: false, comment: comment) }
                    if item.canAlwaysAllow {
                        Button("Allow for this session") { store.decide(item.id, allow: true, comment: comment, always: true) }
                            .help("Like “Yes, don't ask again” in the terminal, but only until the session ends")
                    }
                    Button("Allow") { store.decide(item.id, allow: true, comment: comment) }
                        .buttonStyle(.hoverProminent)
                }
            }
        }
    }

    @ViewBuilder var questions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.questions, id: \.self) { q in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if !q.header.isEmpty { Pill(text: q.header, color: .blue) }
                        Text(q.question).font(.callout.weight(.medium)).textSelection(.enabled)
                    }
                    ForEach(q.options, id: \.self) { o in
                        let on = picks[q.question, default: []].contains(o.label)
                        Button {
                            var cur = picks[q.question, default: []]
                            if q.multiSelect { if on { cur.remove(o.label) } else { cur.insert(o.label) } } else { cur = [o.label] }
                            picks[q.question] = cur
                            if !q.multiSelect { other[q.question] = "" }
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: on ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                     : (q.multiSelect ? "square" : "circle"))
                                    .foregroundStyle(on ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.label)
                                    if !o.description.isEmpty && !compact {
                                        Text(o.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverRow)
                    }
                    TextField("Other answer", text: Binding(get: { other[q.question] ?? "" }, set: {
                        other[q.question] = $0
                        if !$0.isEmpty && !q.multiSelect { picks[q.question] = [] }
                    }))
                    .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Answer") { store.decide(item.id, allow: true, comment: "", answers: answers) }
                    .buttonStyle(.hoverProminent)
                    .disabled(answers.count < item.questions.count)
            }
        }
    }

    var answers: [String: String] {
        var out: [String: String] = [:]
        for q in item.questions {
            var parts = q.options.map(\.label).filter { picks[q.question, default: []].contains($0) }
            if let o = other[q.question]?.trimmed, !o.isEmpty { parts.append(o) }
            if !parts.isEmpty { out[q.question] = parts.joined(separator: ", ") }
        }
        return out
    }
}
