import SwiftUI

struct AgentCard: View {
    @EnvironmentObject var store: Store
    let agent: Agent
    var showProject = false
    var onOpen: () -> Void = {}
    var onMessage: () -> Void = {}
    @State private var reply = ""
    @State private var replyResult: String?

    var body: some View {
        let st = store.status(agent)
        Card(tint: st == .ended || st == .stale ? .clear : st.color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    // No symbolEffect pulse here: the status dot already pulses (cheaply, in Core Animation).
                    Image(systemName: agent.toolIcon).foregroundStyle(.secondary)
                    Text(agent.name).font(.headline)
                    Pill(text: agent.toolLabel)
                    Spacer()
                    StatusBadge(status: st)
                }
                HStack(spacing: 6) {
                    if showProject, let p = store.project(agent.projectId) { Pill(text: p.name, color: .accentColor, icon: "folder") }
                    if !agent.branch.isEmpty { Pill(text: agent.branch, color: .purple, icon: "arrow.triangle.branch") }
                    let unread = store.undelivered(to: agent.id)
                    if unread > 0 { Pill(text: "\(unread) undelivered", color: .teal, icon: "envelope") }
                }
                // The task, in the human's terms, and how far along it is.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("TASK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        if let t = store.currentTask(of: agent.id) {
                            Text("#\(t.id)" + (t.client.isEmpty ? "" : " · \(t.client)")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if agent.progress >= 0 {
                            Text("\(agent.progress)%").font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(agent.progress >= 100 ? .green : .primary)
                        }
                    }
                    Text(goalText.isEmpty ? "No task yet — give it one in its terminal or below." : goalText)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(goalText.isEmpty ? .secondary : .primary)
                        .lineLimit(2, reservesSpace: true)
                    if agent.progress >= 0 { ProgressBar(value: Double(agent.progress) / 100, color: agent.progress >= 100 ? .green : st.color) }
                }
                // What it's doing right now, in plain words (fixed height so the card never jumps).
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(agent.narrative.isEmpty ? "I'll describe what it's doing after its first actions…" : agent.narrative)
                        .font(.callout)
                        .foregroundStyle(agent.narrative.isEmpty ? .secondary : .primary)
                        .lineLimit(3, reservesSpace: true)
                        .help(agent.narrative.isEmpty ? "" : "Updated \(Fmt.rel(agent.narrativeAt, now: store.now))")
                }
                if !agent.stuck.isEmpty && st == .stuck {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.red)
                        Text(agent.stuck).font(.caption).foregroundStyle(.red).lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Message") { onMessage() }.font(.caption).buttonStyle(.hover)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                }
                if st == .waiting || st == .idle || st == .stuck {
                    // Answer the agent right here: typed into its terminal when it waits, queued otherwise.
                    HStack(spacing: 6) {
                        TextField(st == .waiting ? "Reply to \(agent.name)…" : "Next instruction for \(agent.name)…", text: $reply)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendReply)
                        Button(action: sendReply) { Image(systemName: "paperplane.fill") }
                            .disabled(reply.trimmed.isEmpty)
                            .help("Delivered like a message typed in its terminal")
                    }
                }
                if let replyResult { Text(replyResult).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                Divider()
                HStack(spacing: 6) {
                    let done = agent.doneList.count
                    if done > 0 {
                        Label("\(done) done", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            .help(agent.doneList.prefix(4).joined(separator: "\n"))
                    }
                    Text("active " + Fmt.rel(agent.lastSeen, now: store.now)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if st != .ended {
                        Button { store.focusTerminal(agent) { replyResult = $0 } } label: {
                            Label("Terminal", systemImage: "terminal").labelStyle(.titleAndIcon)
                                .font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                        }
                        .buttonStyle(.hoverBordered)
                        .help("Bring its terminal to the front (⌥⌘J — the next agent that needs you)")
                    }
                    Button { onMessage() } label: {
                        Label("Message", systemImage: "text.bubble").labelStyle(.titleAndIcon)
                            .font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.hoverBordered).help("Message the agent's session")
                }
                .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: ThemeStore.shared.density.radius)
        .onTapGesture { onOpen() }
        .contextMenu {
            let others = store.agents.filter { $0.id != agent.id && $0.projectId == agent.projectId && store.status($0) != .ended }
            Menu("Brief another agent on \(agent.name)'s work") {
                ForEach(others) { o in
                    Button(o.name) { store.brief(agent, to: o) { replyResult = $0 } }
                }
                if others.isEmpty { Text("No other open agents in this project") }
            }
            Menu("Brief \(agent.name) on…") {
                ForEach(others) { o in
                    Button("\(o.name)'s work") { store.brief(o, to: agent) { replyResult = $0 } }
                }
                if others.isEmpty { Text("No other open agents in this project") }
            }
            if store.status(agent) != .ended {
                Button("Open its terminal") { store.focusTerminal(agent) { replyResult = $0 } }
            }
        }
    }

    /// The goal in the human's terms: the narrator's summary, else the task title, else the request itself.
    var goalText: String {
        if !agent.goal.isEmpty { return agent.goal }
        if let t = store.currentTask(of: agent.id) { return t.title }
        return agent.lastPrompt.replacingOccurrences(of: "</?[a-z_]+( [^>]*)?>", with: "", options: .regularExpression)
            .oneLine.trimmed.trunc(140)
    }

    func sendReply() {
        let text = reply.trimmed
        guard !text.isEmpty else { return }
        reply = ""
        SessionDelivery.deliver(agentId: agent.id, text: text, mode: .auto) { r in replyResult = r }
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
        // Working agents on top, then a stable order by session start.
        return filtered.sorted { Agent.boardPrecedes($0, $1, staleMinutes: store.staleMinutes, at: store.now) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Show finished and inactive", isOn: $showEnded).toggleStyle(.checkbox)
                Spacer()
                if let projectId {
                    Button { messageTo = MessageTarget(projectId: projectId, agent: nil) } label: {
                        Label("Message all agents", systemImage: "megaphone")
                    }
                }
            }
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No active agents").font(.headline)
                    Text("Run Claude Code in the project folder and the agent will appear here automatically.")
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
                            .transition(.opacity)
                    }
                }
            }
        }
        .animateRows(list.map(\.id))
        // Debug aid (with AGENTBOARD_SNAPSHOT): AGENTBOARD_OPEN_AGENT=<agent id> opens that agent's details.

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
                    Text("Message \(a.name)'s session").font(.title3.bold())
                    Pill(text: a.toolLabel)
                    StatusBadge(status: store.status(a))
                }
                if !a.lastAction.isEmpty {
                    Text("Now: \(a.lastAction)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("Message all active agents in the project").font(.title3.bold())
                Text("Each agent receives it in its context on its next step or next request.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $text).font(.body).frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            if a != nil {
                Picker("Delivery", selection: $mode) {
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
                Button(result == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("Send") { send(a) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.hoverProminent)
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
    @State private var replaying = false

    var body: some View {
        if let a = store.agent(agentId) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: a.toolIcon).font(.title2)
                    TextField("Name", text: $name).font(.title2.bold()).textFieldStyle(.plain)
                        .onSubmit { store.renameAgent(a.id, name) }
                    StatusBadge(status: store.status(a))
                    Spacer()
                    Button("Done") { if name != a.name { store.renameAgent(a.id, name) }; dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AgentStory(agent: a)
                        DisclosureGroup("Technical details: folder, files, timeline, subagents, reservations") {
                            VStack(alignment: .leading, spacing: 12) {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                GridRow { Text("ID").foregroundStyle(.secondary); Text(a.id).textSelection(.enabled) }
                                GridRow { Text("Tool").foregroundStyle(.secondary); Text(a.toolLabel) }
                                GridRow { Text("Folder").foregroundStyle(.secondary); Text(a.cwd).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                                GridRow { Text("Branch").foregroundStyle(.secondary); Text(a.branch.isEmpty ? "—" : a.branch) }
                                GridRow {
                                    Text("Project").foregroundStyle(.secondary)
                                    Picker("", selection: Binding(get: { a.projectId }, set: { store.pinAgent(a.id, to: $0) })) {
                                        ForEach(store.projects) { Text($0.name).tag($0.id) }
                                    }
                                    .labelsHidden().frame(width: 220)
                                    .help("Pin this session to a project (sessions started in ~ or ~/Desktop are guessed from the files they touch)")
                                }
                                GridRow { Text("Started").foregroundStyle(.secondary); Text(Fmt.rel(a.startedAt, now: store.now)) }
                                GridRow { Text("Focus").foregroundStyle(.secondary); Text(a.focus.isEmpty ? "—" : a.focus) }
                            }
                            .font(.callout)
                            if !a.lastPrompt.isEmpty {
                                GroupBox("Last request") {
                                    ScrollView { Text(a.lastPrompt).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                                        .frame(maxHeight: 90)
                                }
                            }
                            HStack(alignment: .top, spacing: 12) {
                                GroupBox("Files") {
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
                                GroupBox("Timeline") {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(store.events.filter { $0.agentId == a.id }.prefix(150)) { e in
                                                HStack(alignment: .top, spacing: 6) {
                                                    Text(Fmt.time(e.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                                    Image(systemName: e.icon).foregroundStyle(e.color).font(.caption)
                                                    Text((e.sub.isEmpty || e.title.hasPrefix("↳") ? "" : "↳ \(e.sub): ") + e.title)
                                                        .font(.caption).lineLimit(3).textSelection(.enabled)
                                                        .padding(.leading, e.sub.isEmpty ? 0 : 10)
                                                }
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(height: 280)
                            let subs = store.subagents(of: a.id)
                            if !subs.isEmpty {
                                GroupBox("Subagents") {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(subs.reversed()) { s in
                                                HStack(alignment: .top, spacing: 8) {
                                                    Image(systemName: s.isRunning ? "bolt.fill" : "checkmark.circle")
                                                        .foregroundStyle(s.isRunning ? .green : .secondary)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        HStack {
                                                            Text(s.type).font(.callout.weight(.medium))
                                                            if !s.description.isEmpty { Text(s.description).font(.caption).foregroundStyle(.secondary) }
                                                            Spacer()
                                                            Text(Fmt.time(s.startedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                                        }
                                                        let line = s.isRunning ? s.lastAction : s.result
                                                        if !line.isEmpty { Text(line.oneLine).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                                    }
                                                }
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 140)
                                }
                            }
                            let held = store.reservations(of: a.id)
                            if !held.isEmpty {
                                GroupBox("File reservations") {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(held) { r in
                                            HStack {
                                                Image(systemName: "lock.fill").foregroundStyle(.orange)
                                                Text(r.pattern).font(.caption.monospaced())
                                                if !r.reason.isEmpty { Text(r.reason).font(.caption).foregroundStyle(.secondary) }
                                                Spacer()
                                                Text("until \(Fmt.time(r.expiresAt))").font(.caption)
                                                Button { store.dropReservation(r.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.hover)
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            let inbox = store.inbox(of: a.id)
                            if !inbox.isEmpty {
                                GroupBox("Messages to the agent") {
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
                            }
                            .padding(.top, 8)
                        }
                        .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 640)
                HStack {
                    Button { messaging = true } label: { Label("Message the session", systemImage: "text.bubble") }
                    Button { replaying = true } label: { Label("Replay", systemImage: "play.square.stack") }
                        .help("Step through everything it did, with the diff of every edit")
                    if !a.transcriptPath.isEmpty {
                        Button { revealInFinder(a.transcriptPath) } label: { Label("Transcript", systemImage: "doc.text") }
                    }
                    Spacer()
                    if a.status != "ended" {
                        Button("Mark as finished") { store.endAgent(a.id) }
                    }
                }
            }
            .padding(20)
            .frame(width: 760)
            .onAppear { name = a.name }
            .sheet(isPresented: $messaging) { MessageSheet(target: MessageTarget(projectId: a.projectId, agent: a.id)) }
            .sheet(isPresented: $replaying) { ReplaySheet(agent: a).environmentObject(store) }
        } else {
            Text("Agent not found").padding(40)
        }
    }
}


/// The session in a manager's terms: the task, how far along, what it is doing, and what it has finished.
struct AgentStory: View {
    @EnvironmentObject var store: Store
    let agent: Agent

    var body: some View {
        let st = store.status(agent)
        let tasks = store.tasks.filter { $0.assignee == agent.id }
        let commits = store.events.filter { $0.agentId == agent.id && $0.kind == "commit" }.prefix(8)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Task").font(.headline)
                    Spacer()
                    if agent.progress >= 0 {
                        Text("\(agent.progress)% done").font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(agent.progress >= 100 ? .green : .primary)
                    }
                }
                Text(goal.isEmpty ? "No task yet." : goal).font(.title3.weight(.semibold))
                    .foregroundStyle(goal.isEmpty ? .secondary : .primary).textSelection(.enabled)
                if agent.progress >= 0 { ProgressBar(value: Double(agent.progress) / 100, color: agent.progress >= 100 ? .green : st.color) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Now").font(.headline)
                    Spacer()
                    if agent.narrativeAt > 0 { Text("updated " + Fmt.rel(agent.narrativeAt, now: store.now)).font(.caption).foregroundStyle(.secondary) }
                }
                Text(agent.narrative.isEmpty ? "I'll describe what it's doing after its first actions…" : agent.narrative)
                    .foregroundStyle(agent.narrative.isEmpty ? .secondary : .primary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What it has done").font(.headline)
                if agent.doneList.isEmpty && tasks.isEmpty && commits.isEmpty {
                    Text("Nothing finished yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(agent.doneList.enumerated()), id: \.offset) { _, line in
                    Label { Text(line).textSelection(.enabled) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                ForEach(tasks) { t in
                    Label {
                        Text("Task #\(t.id) “\(t.title)” — \(t.status.label.lowercased())" + (t.client.isEmpty ? "" : " · \(t.client)"))
                    } icon: {
                        Image(systemName: t.status == .done ? "checkmark.seal.fill" : t.status == .review ? "eye.circle.fill" : "circle.dotted")
                            .foregroundStyle(t.status == .done ? .green : t.status == .review ? .blue : .secondary)
                    }
                }
                ForEach(commits) { e in
                    Label {
                        Text(e.title.replacingOccurrences(of: "\(agent.name): ", with: "").oneLine.trunc(140))
                            .foregroundStyle(.secondary)
                    } icon: { Image(systemName: "arrow.triangle.branch").foregroundStyle(.purple) }
                    .font(.callout)
                }
            }
        }
    }

    var goal: String {
        if !agent.goal.isEmpty { return agent.goal }
        if let t = store.currentTask(of: agent.id) { return t.title }
        return agent.lastPrompt.replacingOccurrences(of: "</?[a-z_]+( [^>]*)?>", with: "", options: .regularExpression)
            .oneLine.trimmed.trunc(160)
    }
}
