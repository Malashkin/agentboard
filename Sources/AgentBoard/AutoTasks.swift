import Foundation

/// Keeps the board in step with real work without relying on agents to call claim_task:
/// the first request of a session becomes a task (short title from a small model), a request that
/// starts something different closes the previous one for review and opens a new one, and a
/// session that ends sends its task to review. Tasks an agent or the human manage themselves are left alone.
final class TaskAutopilot {
    static let shared = TaskAutopilot()
    private let queue = DispatchQueue(label: "agentboard.autopilot")

    static func clean(_ prompt: String) -> String {
        prompt.replacingOccurrences(of: "</?[a-z_]+( [^>]*)?>", with: "", options: .regularExpression).trimmed
    }

    /// Prompts that are not work requests: short replies, slash commands, confirmations.
    static func isWorkRequest(_ p: String) -> Bool {
        let s = p.lowercased()
        if s.count < 15 || s.hasPrefix("/") { return false }
        let trivial = ["да", "нет", "ок", "давай", "продолжай", "дальше", "спасибо",
                       "continue", "yes", "no", "ok", "okay", "go on", "go ahead", "next", "thanks", "thank you"]
        return !trivial.contains { s == $0 || s == $0 + "." || s == $0 + "!" }
    }

    func onPrompt(_ agent: Agent, _ raw: String) {
        guard AppSettings.autoTasks else { return }
        let prompt = Self.clean(raw)
        guard Self.isWorkRequest(prompt) else { return }
        queue.async { self.handle(agentId: agent.id, prompt: prompt) }
    }

    /// Waits until queued work is done (self-test).
    func flush() { queue.sync {} }

    func onSessionEnd(_ agent: Agent) {
        guard AppSettings.autoTasks else { return }
        let core = Core.shared
        core.q.async {
            for t in core.db.query("SELECT * FROM tasks WHERE assignee=? AND status='in_progress' AND created_by='auto'", [agent.id]).map(TaskItem.init) {
                core.updateTask(t.id, status: .review, by: agent.id)
            }
        }
    }

    private func handle(agentId: String, prompt: String) {
        let core = Core.shared
        let (agentOpt, current): (Agent?, TaskItem?) = core.q.sync {
            (core.agent(id: agentId),
             core.db.query("SELECT * FROM tasks WHERE assignee=? AND status IN ('in_progress','review') ORDER BY updated_at DESC LIMIT 1",
                           [agentId]).first.map(TaskItem.init))
        }
        guard let agent = agentOpt else { return }
        // Claimed by the agent itself or assigned by the human: theirs to manage.
        if let current, current.createdBy != "auto" { return }

        var newTitle: String?
        if let current {
            guard let verdict = classify(current: current, prompt: prompt) else { return }
            if verdict.same { return }
            newTitle = verdict.title
            core.q.sync {
                core.updateTask(current.id, status: .review, by: agent.id)
                core.addEvent(project: current.projectId, agent: agent.id, kind: "note",
                              title: "#\(current.id) \"\(current.title.trunc(80))\" → to review: \(agent.name) moved on to another task", ref: "\(current.id)")
            }
        }
        let title = newTitle ?? makeTitle(prompt) ?? Self.fallbackTitle(prompt)
        core.q.sync {
            let client = core.project(id: agent.projectId)?.client ?? ""
            _ = core.createTask(project: agent.projectId, title: title, details: prompt.trunc(2000), client: client,
                                status: .in_progress, assignee: agent.id, createdBy: "auto")
        }
    }

    static func fallbackTitle(_ p: String) -> String {
        let first = p.split(separator: "\n").first.map(String.init) ?? p
        return first.trunc(80)
    }

    private func ask(_ prompt: String) -> String? {
        guard !AppDelegate.isTesting, let claude = Shell.which("claude") else { return nil }
        let r = Shell.run(claude, Shell.modelArgs(model: AppSettings.narratorModel),
                          cwd: Core.shared.supportDir.path, input: prompt, timeout: 60)
        let out = r.out.trimmed
        return r.ok && !out.isEmpty ? out : nil
    }

    private func makeTitle(_ prompt: String) -> String? {
        ask("""
        Write a task title for a kanban board based on the human's request to an AI coding agent below.
        Up to 70 characters, in English, like a to-do item: an imperative verb or a noun phrase, no quotes and no trailing period.
        Reply with the title only.

        Request:
        \(prompt.trunc(3000))
        """).map { $0.oneLine.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'. ")).trunc(90) }
    }

    private func classify(current: TaskItem, prompt: String) -> (same: Bool, title: String?)? {
        guard let out = ask("""
        An AI coding agent is working on the task "\(current.title)".
        Task description: \(current.details.trunc(1200))

        The human sent it a new message:
        \(prompt.trunc(2500))

        Is this a continuation of the same task (a clarification, a fix, the next step, a question about it) or a completely different task?
        Reply with JSON only, no explanations: {"same": true} or {"same": false, "title": "new task title in English, up to 70 characters"}
        """) else { return nil }
        let json = out.range(of: #"\{.*\}"#, options: .regularExpression).map { String(out[$0]) } ?? out
        guard let j = parseJSON(Data(json.utf8)) as? JSON, let same = j["same"] as? Bool else { return nil }
        return (same, j.str("title").map { $0.oneLine.trunc(90) })
    }
}

// MARK: - Time per client and task

/// Working time is counted from the agents' own activity: consecutive events of an agent less than
/// `gap` apart form a working stretch. "Agent time" adds up all agents; "wall time" counts parallel
/// work once — what the day actually took.
struct TimeReport {
    struct Row: Identifiable, Hashable {
        var id: String
        var title: String
        var client: String
        var wall: Double
        var agentTime: Double
        var tasks: [Row] = []
    }
    var clients: [Row]
    var totalWall: Double
    var totalAgent: Double

    static func format(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "<1 min" }
        return m < 60 ? "\(m) min" : "\(m / 60) h \(String(format: "%02d", m % 60)) min"
    }
}

extension Core {
    func timeReport(from: Double, to: Double, project: String?, gap: Double = 300) -> TimeReport {
        var sql = "SELECT agent_id, project_id, task_id, created_at FROM events WHERE created_at >= ? AND created_at < ? AND agent_id IS NOT NULL AND kind NOT IN ('narrative','session_end')"
        var args: [Any] = [from, to]
        if let project { sql += " AND project_id = ?"; args.append(project) }
        let rows = db.query(sql + " ORDER BY agent_id, created_at", args)
        var tasks: [Int64: TaskItem] = [:]
        var projects: [String: Project] = [:]
        func client(_ taskId: Int64?, _ projectId: String) -> (String, String) {
            if let taskId {
                if tasks[taskId] == nil { tasks[taskId] = task(id: taskId) }
                if let t = tasks[taskId] {
                    if !t.client.isEmpty { return (t.client, t.client) }
                }
            }
            if projects[projectId] == nil { projects[projectId] = self.project(id: projectId) }
            let p = projects[projectId]
            if let c = p?.client, !c.isEmpty { return (c, c) }
            return ("project:" + projectId, "Project \"\(p?.name ?? projectId)\"")
        }
        // (clientKey, taskKey, start, end)
        var spans: [(String, String, Double, Double)] = []
        var clientTitles: [String: String] = [:]
        var prev: (agent: String, at: Double, task: Int64?, project: String)?
        for r in rows {
            let a = r.s("agent_id"), at = r.d("created_at"), tid = r.oi("task_id"), pid = r.s("project_id")
            if let p = prev, p.agent == a, at - p.at <= gap {
                let taskId = p.task ?? tid
                let (ck, ct) = client(taskId, p.project)
                clientTitles[ck] = ct
                spans.append((ck, taskId.map { "task:\($0)" } ?? "none:\(p.project)", p.at, at))
            } else {
                // A lone burst still took a moment.
                let (ck, ct) = client(tid, pid)
                clientTitles[ck] = ct
                spans.append((ck, tid.map { "task:\($0)" } ?? "none:\(pid)", at, at + 30))
            }
            prev = (a, at, tid, pid)
        }
        func union(_ s: [(Double, Double)]) -> Double {
            var total = 0.0, curS = -1.0, curE = -1.0
            for (a, b) in s.sorted(by: { $0.0 < $1.0 }) {
                if a > curE { if curE > curS { total += curE - curS }; curS = a; curE = b } else { curE = max(curE, b) }
            }
            if curE > curS { total += curE - curS }
            return total
        }
        var clients: [TimeReport.Row] = []
        for (ck, cspans) in Dictionary(grouping: spans, by: { $0.0 }) {
            var taskRows: [TimeReport.Row] = []
            for (tk, tspans) in Dictionary(grouping: cspans, by: { $0.1 }) {
                let title: String
                if tk.hasPrefix("task:"), let id = Int64(tk.dropFirst(5)), let t = tasks[id] ?? task(id: id) {
                    title = "#\(t.id) \(t.title)"
                } else {
                    title = "No task"
                }
                taskRows.append(.init(id: ck + "|" + tk, title: title, client: clientTitles[ck] ?? ck,
                                      wall: union(tspans.map { ($0.2, $0.3) }), agentTime: tspans.reduce(0) { $0 + $1.3 - $1.2 }))
            }
            clients.append(.init(id: ck, title: clientTitles[ck] ?? ck, client: clientTitles[ck] ?? ck,
                                 wall: union(cspans.map { ($0.2, $0.3) }), agentTime: cspans.reduce(0) { $0 + $1.3 - $1.2 },
                                 tasks: taskRows.sorted { $0.wall > $1.wall }))
        }
        clients.sort { $0.wall > $1.wall }
        return TimeReport(clients: clients, totalWall: union(spans.map { ($0.2, $0.3) }), totalAgent: spans.reduce(0) { $0 + $1.3 - $1.2 })
    }

    func timeReportText(from: Double, to: Double) -> String {
        let r = timeReport(from: from, to: to, project: nil)
        guard r.totalWall > 0 else { return "" }
        var out = ["Agents' working time (from their activity): \(TimeReport.format(r.totalWall)) in total, \(TimeReport.format(r.totalAgent)) summed across agents."]
        for c in r.clients {
            out.append("- \(c.title): \(TimeReport.format(c.wall)) (agent time \(TimeReport.format(c.agentTime)))")
            for t in c.tasks.prefix(8) { out.append("  - \(t.title): \(TimeReport.format(t.wall))") }
        }
        return out.joined(separator: "\n")
    }
}
