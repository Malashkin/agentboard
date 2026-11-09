import Foundation

/// Writes a plain-language line about what each working agent is doing right now
/// ("Fixing the failing auth tests: …"), using a small fast model through `claude -p`.
/// Runs only when an agent has new activity, at most once per agent per interval, one call at a time.
final class Narrator {
    static let shared = Narrator()
    private let queue = DispatchQueue(label: "agentboard.narrator")
    private var timer: DispatchSourceTimer?
    private var lastStatus: [String: String] = [:]
    private var failures = 0

    static let instructions = """
    You write a status line for a board where a human keeps an eye on several AI coding agents.
    Using the data below, describe in English what the agent is doing RIGHT NOW and why: one or two short sentences, no longer than 220 characters.
    Write like a colleague, in plain words: the gist of the work, not a list of commands. Mention file names and technologies only if they matter for understanding.
    If the agent finished its turn — say what it did and what it is waiting for. If it is waiting for the human — say what decision is needed. If it is stuck — say on what.
    No markdown, no quotes, no preamble and no agent name. Start with a verb: "Fixing…", "Investigating…", "Finished…", "Waiting…".
    """

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 20)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard AppSettings.narrator, !AppDelegate.isTesting, let claude = Shell.which("claude") else { return }
        // Back off after repeated failures (no network, logged out…): try again in a few minutes.
        if failures >= 3 { failures -= 1; return }
        let core = Core.shared
        let interval = AppSettings.narratorMinutes * 60
        let jobs: [(Agent, String, Int64)] = core.q.sync {
            var out: [(Agent, String, Int64)] = []
            let open = core.db.query("SELECT * FROM agents WHERE status != 'ended'").map(Agent.init)
                .filter { $0.isActive(staleMinutes: AppSettings.staleMinutes) }
            for a in open {
                let latest = core.db.query("SELECT MAX(id) AS m FROM events WHERE agent_id=? AND kind != 'narrative'", [a.id]).first?.i("m") ?? 0
                let lastNarrated = core.db.query("SELECT narrative_event FROM agents WHERE id=?", [a.id]).first?.i("narrative_event") ?? 0
                guard latest > lastNarrated else { continue }
                let st = a.displayStatus(staleMinutes: AppSettings.staleMinutes).rawValue
                // A finished turn or a question for the human is worth telling at once; ongoing work — once per interval.
                let statusChanged = lastStatus[a.id] != nil && lastStatus[a.id] != st
                guard statusChanged || now() - a.narrativeAt >= interval else { continue }
                out.append((a, Self.context(core, a), latest))
            }
            return out.sorted { $0.0.narrativeAt < $1.0.narrativeAt }
        }
        for (a, ctx, latest) in jobs.prefix(3) {
            let st = a.displayStatus(staleMinutes: AppSettings.staleMinutes).rawValue
            let r = Shell.run(claude, Shell.modelArgs(model: AppSettings.narratorModel),
                              cwd: core.supportDir.path, input: Self.instructions + "\n\n---- DATA ----\n" + ctx, timeout: 60)
            let text = r.out.trimmed.oneLine.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"' ")).trunc(300)
            guard r.ok, !text.isEmpty else { failures += 1; continue }
            failures = 0
            lastStatus[a.id] = st
            core.q.async {
                core.db.update("agents", id: a.id, ["narrative": text, "narrative_at": now(), "narrative_event": latest])
                core.addEvent(project: a.projectId, agent: a.id, kind: "narrative", title: "\(a.name): \(text)")
                core.changed()
            }
        }
    }

    /// What the model sees: the request, task, status and the recent actions, oldest first.
    static func context(_ core: Core, _ a: Agent) -> String {
        var out: [String] = []
        let st = a.displayStatus(staleMinutes: AppSettings.staleMinutes)
        out.append("Status: \(st.label)" + (a.stuck.isEmpty ? "" : " (looks stuck: \(a.stuck))"))
        if let p = core.project(id: a.projectId) { out.append("Project: \(p.name)" + (a.branch.isEmpty ? "" : ", branch \(a.branch)")) }
        if let t = core.db.query("SELECT * FROM tasks WHERE assignee=? AND status IN ('in_progress','review') ORDER BY updated_at DESC LIMIT 1",
                                 [a.id]).first.map(TaskItem.init) {
            out.append("Task: \"\(t.title)\"" + (t.details.isEmpty ? "" : " — \(t.details.trunc(300))"))
        }
        if !a.lastPrompt.isEmpty {
            let prompt = a.lastPrompt.replacingOccurrences(of: "</?[a-z_]+( [^>]*)?>", with: "", options: .regularExpression)
            out.append("The human's last prompt: \"\(prompt.trunc(1200))\"")
        }
        if !a.narrative.isEmpty { out.append("Previous status line (for continuity): \(a.narrative)") }
        let subs = core.db.query("SELECT type, description FROM subagents WHERE agent_id=? AND status='working'", [a.id])
        if !subs.isEmpty { out.append("Subagents running: " + subs.map { "\($0.s("type")) (\($0.s("description")))" }.joined(separator: "; ")) }
        let pending = core.pending.values.filter { $0.commit.agentId == a.id }.map { "\($0.commit.kind): \($0.commit.command.trunc(200))" }
        if !pending.isEmpty { out.append("Waiting for the human's decision: " + pending.joined(separator: "; ")) }
        let events = core.db.query("SELECT * FROM events WHERE agent_id=? AND kind != 'narrative' ORDER BY created_at DESC, id DESC LIMIT 30",
                                   [a.id]).map(EventItem.init).reversed()
        if !events.isEmpty {
            out.append("Recent actions (oldest first):")
            for e in events {
                var line = "- \(Fmt.time(e.createdAt)) " + (e.sub.isEmpty ? "" : "[subagent \(e.sub)] ") + e.title.oneLine.trunc(180)
                if e.kind == "tool_failed" { line += " — error: " + e.detail.oneLine.trunc(160) }
                if e.kind == "turn_done" && !e.detail.isEmpty { line += "\n  Agent's reply: " + e.detail.oneLine.trunc(600) }
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}
