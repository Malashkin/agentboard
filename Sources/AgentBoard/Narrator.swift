import Foundation

/// Writes a plain-language line about what each working agent is doing right now
/// ("Чинит падающие тесты авторизации: …"), using a small fast model through `claude -p`.
/// Runs only when an agent has new activity, at most once per agent per interval, one call at a time.
final class Narrator {
    static let shared = Narrator()
    private let queue = DispatchQueue(label: "agentboard.narrator")
    private var timer: DispatchSourceTimer?
    private var lastStatus: [String: String] = [:]
    private var failures = 0

    static let instructions = """
    Ты пишешь строку статуса для панели, где человек следит за несколькими AI-агентами-программистами.
    По данным ниже опиши по-русски, что агент делает СЕЙЧАС и зачем: одно-два коротких предложения, не длиннее 220 символов.
    Пиши как коллега, простыми словами: суть работы, а не перечень команд. Имена файлов и технологий — только если они важны для понимания.
    Если агент закончил ход — скажи, что сделал и чего ждёт. Если ждёт человека — скажи, какого решения. Если застрял — на чём.
    Без markdown, без кавычек, без вступлений и без имени агента. Начинай с глагола: «Чинит…», «Разбирается…», «Закончил…», «Ждёт…».
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
            let r = Shell.run(claude, ["-p", "--model", AppSettings.narratorModel, "--tools", "", "--no-session-persistence",
                                       "--safe-mode", "--output-format", "text"],
                              cwd: core.supportDir.path, input: Self.instructions + "\n\n---- ДАННЫЕ ----\n" + ctx, timeout: 60)
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
        out.append("Статус: \(st.label)" + (a.stuck.isEmpty ? "" : " (похоже, застрял: \(a.stuck))"))
        if let p = core.project(id: a.projectId) { out.append("Проект: \(p.name)" + (a.branch.isEmpty ? "" : ", ветка \(a.branch)")) }
        if let t = core.db.query("SELECT * FROM tasks WHERE assignee=? AND status IN ('in_progress','review') ORDER BY updated_at DESC LIMIT 1",
                                 [a.id]).first.map(TaskItem.init) {
            out.append("Задача: «\(t.title)»" + (t.details.isEmpty ? "" : " — \(t.details.trunc(300))"))
        }
        if !a.lastPrompt.isEmpty {
            let prompt = a.lastPrompt.replacingOccurrences(of: "</?[a-z_]+( [^>]*)?>", with: "", options: .regularExpression)
            out.append("Последний запрос человека: «\(prompt.trunc(1200))»")
        }
        if !a.narrative.isEmpty { out.append("Прошлая строка статуса (для связности): \(a.narrative)") }
        let subs = core.db.query("SELECT type, description FROM subagents WHERE agent_id=? AND status='working'", [a.id])
        if !subs.isEmpty { out.append("Работают субагенты: " + subs.map { "\($0.s("type")) (\($0.s("description")))" }.joined(separator: "; ")) }
        let pending = core.pending.values.filter { $0.commit.agentId == a.id }.map { "\($0.commit.kind): \($0.commit.command.trunc(200))" }
        if !pending.isEmpty { out.append("Ждёт решения человека: " + pending.joined(separator: "; ")) }
        let events = core.db.query("SELECT * FROM events WHERE agent_id=? AND kind != 'narrative' ORDER BY created_at DESC, id DESC LIMIT 30",
                                   [a.id]).map(EventItem.init).reversed()
        if !events.isEmpty {
            out.append("Последние действия (старые сверху):")
            for e in events {
                var line = "- \(Fmt.time(e.createdAt)) " + (e.sub.isEmpty ? "" : "[субагент \(e.sub)] ") + e.title.oneLine.trunc(180)
                if e.kind == "tool_failed" { line += " — ошибка: " + e.detail.oneLine.trunc(160) }
                if e.kind == "turn_done" && !e.detail.isEmpty { line += "\n  Ответ агента: " + e.detail.oneLine.trunc(600) }
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}
