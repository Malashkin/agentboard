import Foundation

/// End-of-day report: gathers the day's facts and asks Claude Code (`claude -p`) to write the summary.
enum SummaryService {
    static func dayRange(_ day: Date) -> (Double, Double) {
        let start = Calendar.current.startOfDay(for: day)
        return (start.timeIntervalSince1970, start.timeIntervalSince1970 + 86400)
    }

    /// Plain-text dump of everything that happened that day. Safe to call off the core queue.
    static func collect(day: Date) -> (text: String, hasActivity: Bool) {
        let (from, to) = dayRange(day)
        let core = Core.shared
        let projects = core.q.sync { core.allProjects() }
        var out: [String] = ["Дата: \(Fmt.dayHuman.string(from: day))"]
        var any = false

        for p in projects {
            let data = core.q.sync { () -> (agents: [Agent], events: [EventItem], tasks: [TaskItem], files: [Row]) in
                let agents = core.db.query("SELECT * FROM agents WHERE project_id=? AND last_seen >= ? AND started_at < ?",
                                           [p.id, from, to]).map(Agent.init)
                let events = core.db.query("SELECT * FROM events WHERE project_id=? AND created_at >= ? AND created_at < ? ORDER BY id",
                                           [p.id, from, to]).map(EventItem.init)
                let tasks = core.db.query("SELECT * FROM tasks WHERE project_id=? AND ((updated_at >= ? AND updated_at < ?) OR (created_at >= ? AND created_at < ?))",
                                          [p.id, from, to, from, to]).map(TaskItem.init)
                let files = core.db.query("SELECT f.path, f.count, a.name FROM file_touches f JOIN agents a ON a.id=f.agent_id WHERE f.project_id=? AND f.last_at >= ? AND f.last_at < ? ORDER BY f.count DESC LIMIT 60",
                                          [p.id, from, to])
                return (agents, events, tasks, files)
            }
            let since = Fmt.gitDate.string(from: Date(timeIntervalSince1970: from))
            let until = Fmt.gitDate.string(from: Date(timeIntervalSince1970: to))
            let log = Shell.git(["log", "--all", "--no-merges", "--since=\(since)", "--until=\(until)",
                                 "--format=%n%h %ad %an [%D]%n  %s%n%b", "--date=format-local:%H:%M", "--shortstat", "-n", "150"],
                                cwd: p.path, timeout: 30).out.trimmed

            if data.events.isEmpty && data.tasks.isEmpty && log.isEmpty { continue }
            any = true
            var sec: [String] = ["\n=== ПРОЕКТ: \(p.name) (\(p.path))\(p.client.isEmpty ? "" : ", клиент по умолчанию: \(p.client)") ==="]
            let names = Dictionary(uniqueKeysWithValues: data.agents.map { ($0.id, $0.name) })
            func who(_ id: String?) -> String {
                guard let id else { return "человек" }
                if let n = names[id] { return n }
                return core.q.sync { core.agent(id: id)?.name } ?? "человек"
            }

            if !data.agents.isEmpty {
                sec.append("Агенты за день:")
                for a in data.agents { sec.append("- \(a.name) (\(a.toolLabel), ветка \(a.branch.isEmpty ? "?" : a.branch))") }
            }
            if !log.isEmpty { sec.append("Коммиты (git log):\n" + log.trunc(14000)) }
            let commitEvents = data.events.filter { $0.kind == "commit" }
            if !commitEvents.isEmpty {
                sec.append("Кто из агентов делал коммиты:")
                for e in commitEvents { sec.append("- \(Fmt.time(e.createdAt)) \(who(e.agentId)): \(e.title)") }
            }
            if !data.tasks.isEmpty {
                sec.append("Задачи (изменялись за день):")
                for t in data.tasks {
                    sec.append("- #\(t.id) [\(t.status.label)] \(t.title) | клиент: \(t.client.isEmpty ? "—" : t.client) | исполнитель: \(who(t.assignee))"
                               + (t.details.isEmpty ? "" : "\n  " + t.details.oneLine.trunc(300)))
                }
            }
            let byAgent = Dictionary(grouping: data.events.filter { $0.kind == "prompt" }, by: { $0.agentId ?? "" })
            if !byAgent.isEmpty {
                sec.append("Запросы человека к агентам:")
                for (aid, evs) in byAgent {
                    sec.append("  \(who(aid)):")
                    for e in evs.prefix(25) { sec.append("  - \(Fmt.time(e.createdAt)) \(e.detail.oneLine.trunc(300))") }
                }
            }
            let answers = data.events.filter { $0.kind == "turn_done" && !$0.detail.isEmpty }
            if !answers.isEmpty {
                sec.append("Итоговые ответы агентов (последние):")
                for e in answers.suffix(30) { sec.append("- \(Fmt.time(e.createdAt)) \(who(e.agentId)): \(e.detail.oneLine.trunc(500))") }
            }
            let notable = data.events.filter { ["note", "message", "conflict", "commit_denied", "commit_timeout", "push", "waiting"].contains($0.kind) }
            if !notable.isEmpty {
                sec.append("Заметки, сообщения, конфликты, отклонённые коммиты:")
                for e in notable.suffix(60) {
                    sec.append("- \(Fmt.time(e.createdAt)) [\(e.kind)] \(e.title.oneLine.trunc(250))\(e.client.isEmpty ? "" : " (клиент: \(e.client))")")
                }
            }
            if !data.files.isEmpty {
                sec.append("Самые изменяемые файлы: " + data.files.prefix(30).map { "\($0.s("path")) (\($0.s("name")), ×\($0.i("count")))" }.joined(separator: ", "))
            }
            out.append(sec.joined(separator: "\n").trunc(40000))
        }
        return (out.joined(separator: "\n"), any)
    }

    static let instructions = """
    Ты пишешь вечернюю сводку работы AI-агентов (Claude Code, Codex) для их руководителя-человека.
    Ниже — сырые данные за день: коммиты, задачи с клиентами, запросы к агентам, их ответы, заметки и конфликты.
    Сформируй отчёт в Markdown на русском, строго по данным, ничего не выдумывай:

    # Сводка за <дата>
    ## Главное
    3–6 пунктов: самое важное, что сделано за день.
    ## По проектам — код
    Для каждого проекта: что сделано в коде (по смыслу коммитов, не перечисляй хеши без нужды), какие агенты что делали.
    ## По клиентам
    Для каждого клиента: что сделано, что в работе. Если клиент не указан — раздел «Без клиента».
    ## В работе и незакончено
    Открытые задачи, незакоммиченная работа, на чём остановились агенты.
    ## Требует внимания
    Конфликты между агентами, отклонённые коммиты, где агенты ждали человека, риски. Если ничего — так и напиши.

    Пиши кратко и по делу, как для занятого человека. Ответ — только Markdown отчёта.
    """

    static func fallbackReport(day: Date, raw: String, reason: String) -> String {
        "# Сводка за \(Fmt.dayHuman.string(from: day))\n\n> Автоматический текст не получен (\(reason)). Ниже — собранные факты.\n\n```\n\(raw.trunc(60000))\n```\n"
    }

    /// Generates, stores and exports the summary. Calls back on the main queue.
    static func generate(day: Date, completion: @escaping (Result<SummaryItem, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (raw, any) = collect(day: day)
            var markdown: String
            var source = "claude"
            if !any {
                markdown = "# Сводка за \(Fmt.dayHuman.string(from: day))\n\nЗа этот день активности агентов не зафиксировано."
                source = "empty"
            } else if let claude = Shell.which("claude") {
                var args = ["-p", "--output-format", "text"]
                if !AppSettings.summaryModel.isEmpty { args += ["--model", AppSettings.summaryModel] }
                let r = Shell.run(claude, args, cwd: Core.shared.supportDir.path,
                                  input: instructions + "\n\n---- ДАННЫЕ ----\n" + raw, timeout: 600)
                if r.ok && !r.line.isEmpty {
                    markdown = r.line
                } else {
                    markdown = fallbackReport(day: day, raw: raw, reason: "claude: " + (r.err.trimmed.isEmpty ? "код \(r.code)" : r.err.trimmed.trunc(300)))
                    source = "raw"
                }
            } else {
                markdown = fallbackReport(day: day, raw: raw, reason: "не найден claude CLI")
                source = "raw"
            }
            let key = Fmt.dayKey.string(from: day)
            let item: SummaryItem = Core.shared.q.sync {
                Core.shared.db.query("INSERT INTO summaries(day, markdown, source, created_at) VALUES(?,?,?,?)", [key, markdown, source, now()])
                let row = Core.shared.db.query("SELECT * FROM summaries WHERE id=?", [Core.shared.db.lastInsertId]).first!
                Core.shared.changed()
                return SummaryItem(row)
            }
            export(item)
            DispatchQueue.main.async { completion(.success(item)) }
        }
    }

    @discardableResult
    static func export(_ s: SummaryItem) -> String? {
        let dir = (AppSettings.exportDir as NSString).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/\(s.day).md"
            try s.markdown.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    static func exportPath(_ s: SummaryItem) -> String {
        (AppSettings.exportDir as NSString).expandingTildeInPath + "/\(s.day).md"
    }
}
