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

    private var reloadScheduled = false
    private var ticker: AnyCancellable?

    init() {
        ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] d in self?.now = d }
    }

    var staleMinutes: Double { AppSettings.staleMinutes }

    func scheduleReload() {
        DispatchQueue.main.async {
            guard !self.reloadScheduled else { return }
            self.reloadScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.reload() }
        }
    }

    func reload() {
        Core.shared.q.async {
            let s = Core.shared.snapshot()
            DispatchQueue.main.async {
                self.reloadScheduled = false
                ThemeStore.animate { self.apply(s) }
            }
        }
    }

    private func apply(_ s: Core.Snapshot) {
        projects = s.projects
        agents = s.agents
        tasks = s.tasks
        events = s.events
        files = s.files
        summaries = s.summaries
        pending = s.pending
        messages = s.messages
    }

    func requestOpenMain() { openMainTick += 1 }

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

    var waitingCount: Int { activeAgents().filter { status($0) == .waiting }.count + pending.count }

    func todayEvents(kind: String, project: String? = nil) -> [EventItem] {
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        return events.filter { $0.kind == kind && $0.createdAt >= start && (project == nil || $0.projectId == project) }
    }

    // MARK: Actions (forwarded to Core)

    private func core(_ work: @escaping (Core) -> Void) {
        Core.shared.q.async { work(Core.shared) }
    }

    func addProject(path: String, completion: @escaping (String?) -> Void) {
        core { c in
            let r = c.addProject(path: path)
            DispatchQueue.main.async {
                switch r {
                case .success(let p):
                    completion(nil)
                    GitMonitor.shared.refreshNow()
                    // Commits from any agent (incl. Codex) are caught by a git hook.
                    DispatchQueue.global().async { try? Integrations.installGitHook(p) }
                case .failure(let e): completion(e.message)
                }
            }
        }
    }
    func updateProject(_ id: String, name: String, client: String) { core { $0.updateProject(id: id, name: name, client: client) } }
    func removeProject(_ id: String) { core { $0.removeProject(id: id) } }

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
            c.addEvent(project: project, agent: nil, kind: "note", title: "Вы: \(text.oneLine.trunc(200))", detail: text, client: client)
            c.changed()
        }
    }

    func decide(_ id: String, allow: Bool, comment: String) {
        core { $0.resolveCommit(id: id, allow: allow, comment: comment) }
    }

    func generateSummary(day: Date) {
        let key = Fmt.dayKey.string(from: day)
        guard !generatingDays.contains(key) else { return }
        generatingDays.insert(key)
        SummaryService.generate(day: day) { [weak self] result in
            self?.generatingDays.remove(key)
            if case .success(let s) = result {
                Notifier.shared.post("Сводка за \(s.day) готова", s.markdown.split(separator: "\n").dropFirst().first.map(String.init) ?? "")
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
                lastError = "Автозапуск: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
