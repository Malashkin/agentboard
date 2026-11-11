import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// UI state, mirrored from Core. Mutated only on the main thread.
final class Store: ObservableObject {
    static let shared = Store()

    @Published var projects: [Project] = []
    @Published var agents: [Agent] = []
    @Published var tasks: [TaskItem] = []
    @Published var events: [EventItem] = []
    @Published var files: [FileTouch] = []
    @Published var summaries: [SummaryItem] = []
    @Published var pending: [PendingCommit] = []
    @Published var messages: [MessageItem] = []
    @Published var git: [String: GitSnapshot] = [:]
    @Published var serverRunning = false
    @Published var serverError: String?
    @Published var generatingDays: Set<String> = []
    @Published var now = Date()
    @Published var openMainTick = 0
    @Published var lastError: String?
    @Published var importing: Set<String> = []
    @Published var lastWork: [String: Double] = [:]
    @Published var reservations: [Reservation] = []
    @Published var awayDigest: AwayDigest?
    @Published var subagents: [SubagentItem] = []
    @Published var importReport: [String: String] = [:]
    /// Folders where agents worked recently that aren't on the board (see ProjectDiscovery).
    @Published var suggestions: [ProjectDiscovery.Candidate] = []
    /// Folder → when a live session from it last reached AgentBoard (hooks / Codex) while it wasn't on the board.
    @Published var liveFolders: [String: Double] = [:]
    /// "Not now" on the live banner: hidden for this run of the app, still listed under Suggested.
    @Published var dismissedLive: Set<String> = []
    @Published var ignoredCount = ProjectDiscovery.ignored.count
    private var scanning = false
    private var rescanPending = false

    private var reloadScheduled = false
    private var ticker: AnyCancellable?

    init() {
        // Refreshes relative times ("2 min ago") and idle detection. Every change of `now` re-renders the window,
        // so: every 15 s, and not at all while the app is hidden or fully covered (caught up when it shows again).
        ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] d in
            if AppVisibility.isVisible { self?.now = d }
        }
        AppVisibility.onShow = { [weak self] in self?.now = Date(); GitMonitor.shared.refreshNow() }
    }

    var staleMinutes: Double { AppSettings.staleMinutes }

    func scheduleReload() {
        DispatchQueue.main.async {
            guard !self.reloadScheduled else { return }
            self.reloadScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.reload() }
        }
    }

    func reload() {
        Core.shared.q.async {
            let s = Core.shared.snapshot()
            DispatchQueue.main.async {
                self.reloadScheduled = false
                // No global animation: changed text (last action, status) must not cross-fade on every
                // update. Lists animate only when rows are added or removed (see `.animateRows`).
                self.apply(s)
            }
        }
    }

    /// Only publishes what actually changed: re-assigning equal arrays made SwiftUI redraw
    /// (and re-run transitions in) the feed and agent cards on every hook event — visible as flicker.
    private func apply(_ s: Core.Snapshot) {
        if projects != s.projects {
            let first = projects.isEmpty
            projects = s.projects
            if !first { checkedFolders.removeAll(); refreshSuggestions() }
        }
        if agents != s.agents { agents = s.agents }
        if tasks != s.tasks { tasks = s.tasks }
        if events != s.events { events = s.events }
        if files != s.files { files = s.files }
        if summaries != s.summaries { summaries = s.summaries }
        if pending != s.pending { pending = s.pending }
        if messages != s.messages { messages = s.messages }
        if lastWork != s.lastWork { lastWork = s.lastWork }
        if reservations != s.reservations { reservations = s.reservations }
        if subagents != s.subagents { subagents = s.subagents }
    }


    func requestOpenMain() { openMainTick += 1 }

    // MARK: Suggested projects

    /// Re-reads recent Claude Code / Codex sessions off the main thread. Calls while a scan runs coalesce into one more.
    func refreshSuggestions() {
        if scanning { rescanPending = true; return }
        scanning = true
        core { c in
            let known = (c.allProjects() + c.archivedProjects()).map { ProjectDiscovery.Known(path: $0.path, commonDir: $0.commonDir) }
            DispatchQueue.global(qos: .background).async {
                let found = ProjectDiscovery.scan(known: known)
                DispatchQueue.main.async {
                    if self.suggestions != found { ThemeStore.animate { self.suggestions = found } }
                    self.scanning = false
                    if self.rescanPending { self.rescanPending = false; self.refreshSuggestions() }
                }
            }
        }
    }

    /// A session is running in a folder that isn't on the board: rescan so it shows up while it works.
    func noteUnknownFolder(_ cwd: String) {
        liveFolders[cwd] = Date().timeIntervalSince1970
        // Rescan once per new folder: an agent working in ~ (excluded) must not trigger a scan every 30 s.
        guard !checkedFolders.contains(cwd) else { return }
        checkedFolders.insert(cwd)
        if ProjectDiscovery.isExcluded(cwd, ProjectDiscovery.defaultExcluded) { return }
        if !suggestions.contains(where: { Self.covers($0, cwd) }) { refreshSuggestions() }
    }
    /// Folders from live sessions already checked by a scan (cleared when the board's projects change).
    private var checkedFolders: Set<String> = []

    static func covers(_ c: ProjectDiscovery.Candidate, _ cwd: String) -> Bool { cwd == c.path || cwd.hasPrefix(c.path + "/") }

    /// The suggestion an agent is working in right now (last 15 min), unless dismissed.
    var liveSuggestion: ProjectDiscovery.Candidate? {
        let horizon = now.timeIntervalSince1970 - 900
        return suggestions.compactMap { c -> (ProjectDiscovery.Candidate, Double)? in
            guard !dismissedLive.contains(c.path) else { return nil }
            let t = liveFolders.filter { Self.covers(c, $0.key) }.map(\.value).max() ?? 0
            return t >= horizon ? (c, t) : nil
        }.max { $0.1 < $1.1 }?.0
    }

    func addSuggestion(_ c: ProjectDiscovery.Candidate, completion: @escaping (String?) -> Void) {
        addProject(path: c.path) { err in
            if err == nil { ThemeStore.animate { self.suggestions.removeAll { $0.path == c.path } } }
            completion(err)
        }
    }

    /// Never suggested again (kept in UserDefaults); adding the folder by hand still works.
    func ignoreSuggestion(_ c: ProjectDiscovery.Candidate) {
        ProjectDiscovery.ignore(c.path)
        ignoredCount = ProjectDiscovery.ignored.count
        ThemeStore.animate { suggestions.removeAll { $0.path == c.path } }
    }

    /// Ignored folders are suggested again (if agents still worked there in the last 60 days).
    func clearIgnoredSuggestions() {
        ProjectDiscovery.clearIgnored()
        ignoredCount = 0
        refreshSuggestions()
    }

    // MARK: Sidebar order (drag to reorder)

    @Published var projectOrder: [String] = UserDefaults.standard.stringArray(forKey: "projectOrder") ?? []

    var orderedProjects: [Project] {
        projects.sorted { a, b in
            let ia = projectOrder.firstIndex(of: a.id) ?? Int.max, ib = projectOrder.firstIndex(of: b.id) ?? Int.max
            return ia == ib ? a.name.localizedCompare(b.name) == .orderedAscending : ia < ib
        }
    }

    func moveProjects(from: IndexSet, to: Int) {
        var ids = orderedProjects.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        ThemeStore.animate { projectOrder = ids }
        UserDefaults.standard.set(ids, forKey: "projectOrder")
    }

    // MARK: Lookups

    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    func agent(_ id: String?) -> Agent? { id.flatMap { i in agents.first { $0.id == i } } }
    func agentName(_ id: String?) -> String? { agent(id)?.name }

    func status(_ a: Agent) -> AgentStatus { a.displayStatus(staleMinutes: staleMinutes, at: now) }

    func activeAgents(in project: String? = nil) -> [Agent] {
        agents.filter { (project == nil || $0.projectId == project) && $0.isActive(staleMinutes: staleMinutes, at: now) }
    }
    func agents(in project: String) -> [Agent] { agents.filter { $0.projectId == project } }
    func tasks(in project: String) -> [TaskItem] { tasks.filter { $0.projectId == project } }
    func currentTask(of agent: String) -> TaskItem? {
        tasks.first { $0.assignee == agent && ($0.status == .in_progress || $0.status == .review) }
    }
    func files(of agent: String) -> [FileTouch] { files.filter { $0.agentId == agent } }
    func clients(in project: String?) -> [String] {
        let fromTasks = tasks.filter { project == nil || $0.projectId == project }.map(\.client)
        let fromProjects = projects.filter { project == nil || $0.id == project }.map(\.client)
        return Array(Set((fromTasks + fromProjects).filter { !$0.isEmpty })).sorted()
    }
    func inbox(of agent: String) -> [MessageItem] { messages.filter { $0.toAgent == agent } }
    func undelivered(to agent: String) -> Int { messages.filter { $0.toAgent == agent && $0.deliveredAt == nil }.count }

    /// Agents waiting on you plus open requests — an agent with an open request counts once.
    var waitingCount: Int {
        let withRequest = Set(pending.map(\.agentId))
        return activeAgents().filter { status($0) == .waiting && !withRequest.contains($0.id) }.count + pending.count
    }


    // MARK: Actions (forwarded to Core)

    private func core(_ work: @escaping (Core) -> Void) {
        Core.shared.q.async { work(Core.shared) }
    }

    /// Pulls in sessions and commits that happened before the project was added.
    func importHistory(_ p: Project) {
        guard !importing.contains(p.id) else { return }
        importing.insert(p.id)
        DispatchQueue.global(qos: .utility).async {
            let r = HistoryImporter.run(project: p)
            DispatchQueue.main.async {
                self.importing.remove(p.id)
                self.importReport[p.id] = r.sessions + r.commits == 0 ? "No new data found"
                    : "Imported: \(r.sessions) sessions, \(r.events) events, \(r.commits) commits"
                self.reload()
            }
        }
    }

    func addProject(path: String, completion: @escaping (String?) -> Void) {
        core { c in
            let r = c.addProject(path: path)
            DispatchQueue.main.async {
                switch r {
                case .success(let p):
                    completion(nil)
                    GitMonitor.shared.refreshNow()
                    self.importHistory(p)
                    // Commits from any agent (incl. Codex) are caught by a git hook.
                    DispatchQueue.global().async { try? Integrations.installGitHook(p) }
                case .failure(let e): completion(e.message)
                }
            }
        }
    }
    func updateProject(_ id: String, name: String, client: String) { core { $0.updateProject(id: id, name: name, client: client) } }
    func removeProject(_ id: String) { core { $0.removeProject(id: id) } }
    func renameProject(_ id: String, _ name: String) { core { $0.renameProject(id: id, to: name) } }
    /// Off the sidebar, data kept; "Add project" with the same folder brings it back.
    func archiveProject(_ id: String) { core { $0.archiveProject(id: id) } }

    func createTask(project: String, title: String, details: String, client: String, status: TaskStatus, assignee: String?) {
        core { $0.createTask(project: project, title: title, details: details, client: client, status: status, assignee: assignee, createdBy: "user") }
    }
    func saveTask(_ t: TaskItem) {
        core { $0.updateTask(t.id, title: t.title, details: t.details, client: t.client, status: t.status, assignee: .some(t.assignee)) }
    }
    func moveTask(_ id: Int64, to status: TaskStatus) { core { $0.updateTask(id, status: status) } }
    func deleteTask(_ id: Int64) { core { $0.deleteTask(id) } }

    func renameAgent(_ id: String, _ name: String) { core { $0.renameAgent(id, to: name) } }
    func endAgent(_ id: String) { core { $0.endAgent(id) } }
    func purgeAgents(project: String) { core { $0.purgeEndedAgents(project: project) } }

    func sendMessage(project: String, to agent: String?, text: String) {
        core { $0.sendMessage(project: project, to: agent, from: nil, text: text) }
    }
    func addNote(project: String, text: String, client: String) {
        core { c in
            c.addEvent(project: project, agent: nil, kind: "note", title: "You: \(text.oneLine.trunc(200))", detail: text, client: client)
            c.changed()
        }
    }

    func decide(_ id: String, allow: Bool, comment: String, answers: [String: String] = [:], always: Bool = false) {
        core { $0.resolveCommit(id: id, allow: allow, comment: comment, answers: answers, always: always) }
    }

    func reservations(of agent: String) -> [Reservation] { reservations.filter { $0.agentId == agent } }
    func subagents(of agent: String) -> [SubagentItem] { subagents.filter { $0.agentId == agent } }
    func dropReservation(_ id: Int64) { core { $0.dropReservation(id: id) } }
    func pinAgent(_ id: String, to project: String) { core { $0.pinAgent(id, to: project) } }

    // MARK: Getting to an agent

    /// Agents that need the human, in the order to visit them (see `Attention.queue`).
    var attentionQueue: [Agent] {
        Attention.queue(agents, status: status, requested: Set(pending.map(\.agentId)))
    }

    /// Brings the agent's terminal to the front (off the main thread); `done` gets a short result.
    func focusTerminal(_ a: Agent, done: @escaping (String) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = TerminalFocus.focus(a)
            DispatchQueue.main.async {
                switch r {
                case .success(let how): done("Opened \(a.name)'s terminal (\(how)).")
                case .failure(let e): done(e.message)
                }
            }
        }
    }

    private var lastJumped: String?

    /// ⌥⌘J: the next agent that needs you, terminal to the front; nobody waiting → the answer panel says so.
    func jumpToNextAgent() {
        guard let a = Attention.next(after: lastJumped, in: attentionQueue) else { QuickPanel.shared.show(); return }
        lastJumped = a.id
        focusTerminal(a) { msg in
            if !msg.hasPrefix("Opened") { Notifier.shared.post(a.name, msg) }
        }
    }

    /// Runs git/terminal work off the main thread; completion on main with an error text or nil.
    func workspace(_ work: @escaping () throws -> String?, done: @escaping (String?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ok = try work()
                DispatchQueue.main.async { done(ok, nil); self.reload() }
            } catch {
                DispatchQueue.main.async { done(nil, error.localizedDescription); self.reload() }
            }
        }
    }

    func generateSummary(day: Date) {
        let key = Fmt.dayKey.string(from: day)
        guard !generatingDays.contains(key) else { return }
        generatingDays.insert(key)
        SummaryService.generate(day: day) { [weak self] result in
            self?.generatingDays.remove(key)
            if case .success(let s) = result {
                Notifier.shared.post("Summary for \(s.day) is ready", s.markdown.split(separator: "\n").dropFirst().first.map(String.init) ?? "")
            }
        }
    }

    func deleteSummary(_ id: Int64) {
        core { c in c.db.query("DELETE FROM summaries WHERE id=?", [id]); c.changed() }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}

/// Whether any AgentBoard window is on screen. Background work slows down when it isn't.
enum AppVisibility {
    private static let lock = NSLock()
    private static var visible = true
    static var onShow: (() -> Void)?
    private static var observer: NSObjectProtocol?

    static var isVisible: Bool { lock.lock(); defer { lock.unlock() }; return visible }

    /// Call once on the main thread at launch.
    static func start() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification,
                                                          object: nil, queue: .main) { _ in update() }
        update()
    }

    private static func update() {
        let now = NSApp.occlusionState.contains(.visible)
        lock.lock(); let was = visible; visible = now; lock.unlock()
        if now && !was { onShow?() }
    }
}
