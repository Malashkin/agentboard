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
    You keep a board where a human watches several AI coding agents. From the data below, describe this agent's session \
    for the human in plain English — like a colleague reporting to a manager, not a log.
    Answer with ONLY a JSON object, no markdown, no preamble:
    {"goal": "...", "progress": 0, "now": "...", "done": ["...", "..."]}
    - goal: the task the human gave this agent, summarized in one short sentence (max 110 characters). If the human \
    changed course, the current goal. Not a command list. Example: "Make the Terminal button work and bigger on agent cards".
    - progress: how much of that goal is done, 0–100, your honest estimate from the actions and replies \
    (finished and answered → 100; just started → 5–15). Use -1 only if there is nothing to judge.
    - now: what it is doing RIGHT NOW and why, one or two short sentences, max 200 characters, starting with a verb \
    ("Fixing…", "Checking…", "Finished…", "Waiting for your answer on…"). If it waits for the human, say what decision is needed. \
    If it is stuck, say on what.
    - done: what it has already accomplished in this session, as results a manager understands, past tense, newest first, \
    at most 8 items, each max 120 characters ("Closed task #12 — the Terminal button now opens the right tab", \
    "Added hover effects to every button", "Committed the fix (8b44215)"). Keep earlier items that are still true \
    (they are given below), merge duplicates, drop trivia like reading files. Empty list if nothing is finished yet.
    Mention file names or technologies only where they help understanding.
    """

    struct Report: Equatable {
        var goal: String
        var progress: Int
        var now: String
        var done: [String]
    }

    /// The model's answer → a report. Tolerates code fences and text around the JSON; a plain sentence
    /// (older behaviour, or a model that ignored the format) becomes `now` alone.
    static func parse(_ raw: String) -> Report? {
        let text = raw.trimmed
        guard !text.isEmpty else { return nil }
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
           let o = parseJSON(Data(text[a...b].utf8)) as? JSON {
            let now = o.s("now").oneLine.trimmed.trunc(260)
            let goal = o.s("goal").oneLine.trimmed.trunc(160)
            var p = (o["progress"] as? NSNumber)?.intValue ?? Int(o.s("progress")) ?? -1
            if p != -1 { p = max(0, min(100, p)) }
            let done = ((o["done"] as? [Any]) ?? []).compactMap { ($0 as? String)?.oneLine.trimmed.trunc(160) }
                .filter { !$0.isEmpty }.prefix(8)
            guard !now.isEmpty || !goal.isEmpty else { return nil }
            return Report(goal: goal, progress: p, now: now, done: Array(done))
        }
        let line = text.oneLine.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"' ")).trunc(300)
        return Report(goal: "", progress: -1, now: line, done: [])
    }

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
            guard r.ok, let rep = Self.parse(r.out) else { failures += 1; continue }
            failures = 0
            lastStatus[a.id] = st
            core.q.async { Self.store(rep, agent: a, event: latest, core: core) }
        }
    }

    /// Saves a report on the agent (empty parts keep what was there: a model that only answered `now`
    /// doesn't wipe the goal or the done list).
    static func store(_ rep: Report, agent a: Agent, event: Int64, core: Core) {
        var f: [String: Any] = ["narrative_at": now(), "narrative_event": event]
        if !rep.now.isEmpty { f["narrative"] = rep.now }
        if !rep.goal.isEmpty { f["goal"] = rep.goal }
        if rep.progress >= 0 || !rep.goal.isEmpty { f["progress"] = rep.progress }
        if !rep.done.isEmpty { f["done_list"] = jsonString(rep.done) }
        core.db.update("agents", id: a.id, f)
        if !rep.now.isEmpty { core.addEvent(project: a.projectId, agent: a.id, kind: "narrative", title: "\(a.name): \(rep.now)") }
        core.changed()
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
        let prompts = core.db.query("SELECT detail FROM events WHERE agent_id=? AND kind='prompt' ORDER BY created_at DESC, id DESC LIMIT 5",
                                    [a.id]).map { $0.s("detail").oneLine.trunc(400) }.reversed()
        if prompts.count > 1 { out.append("The human's requests in this session (oldest first):\n" + prompts.map { "- " + $0 }.joined(separator: "\n")) }
        if !a.goal.isEmpty { out.append("Previous goal summary: \(a.goal)" + (a.progress >= 0 ? " (\(a.progress)% done)" : "")) }
        if !a.narrative.isEmpty { out.append("Previous status line (for continuity): \(a.narrative)") }
        if !a.doneList.isEmpty { out.append("Already accomplished (keep what is still true):\n" + a.doneList.map { "- " + $0 }.joined(separator: "\n")) }
        let closed = core.db.query("SELECT * FROM tasks WHERE assignee=? AND status IN ('review','done') ORDER BY updated_at DESC LIMIT 5",
                                   [a.id]).map(TaskItem.init)
        if !closed.isEmpty { out.append("Its tasks that are finished or in review: " + closed.map { "#\($0.id) \"\($0.title)\" (\($0.status.label))" }.joined(separator: "; ")) }
        let commits = core.db.query("SELECT title FROM events WHERE agent_id=? AND kind='commit' ORDER BY created_at DESC LIMIT 5", [a.id])
        if !commits.isEmpty { out.append("Its commits: " + commits.map { $0.s("title").oneLine.trunc(140) }.joined(separator: "; ")) }
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
