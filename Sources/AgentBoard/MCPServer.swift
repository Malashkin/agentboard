import Foundation

/// MCP over Streamable HTTP (JSON responses only, no SSE). Runs on Core.q.
extension Core {
    static let mcpInstructions = """
    AgentBoard — общая панель для нескольких AI-агентов (Claude Code, Codex), работающих над одним проектом; \
    человек видит её в приложении AgentBoard. Используй её, чтобы знать, кто что делает, и не мешать друг другу.
    • board — кто сейчас работает, открытые задачи, свежие коммиты и заметки. Вызови в начале работы.
    • agent_activity(agent) — подробно, что делает конкретный агент: запросы, команды, файлы, последний ответ. \
    Используй, когда человек просит «посмотри, что делает соседний агент / другой терминал / Вега».
    • claim_task / create_task(claim=true) — возьми задачу перед работой; update_task — статус и итог.
    • set_focus(focus, files) — объяви, над чем работаешь и какие файлы трогаешь.
    • send_message(to, text) — написать другому агенту или всем (to="all"); post_note — заметка в ленту для человека.
    • who_touches(path) — кто недавно менял файл.
    Claude Code определяется автоматически. Другие клиенты (Codex и т.п.) сначала вызывают register_agent(cwd) \
    и передают полученный agent_id во все вызовы.
    """

    private static func prop(_ type: String, _ desc: String) -> JSON { ["type": type, "description": desc] }
    private static let agentIdProp = prop("string", "Твой agent_id (Claude Code определяется автоматически, его можно не передавать)")
    private static let projectProp = prop("string", "Путь к проекту, если agent_id неизвестен")

    static var toolDefs: [JSON] {
        func tool(_ name: String, _ desc: String, _ props: JSON, _ required: [String] = [], readOnly: Bool = false) -> JSON {
            var p = props
            p["agent_id"] = agentIdProp
            p["project_path"] = projectProp
            return ["name": name, "description": desc,
                    "inputSchema": ["type": "object", "properties": p, "required": required],
                    "annotations": ["readOnlyHint": readOnly]]
        }
        let statusEnum: JSON = ["type": "string", "enum": TaskStatus.allCases.map(\.rawValue),
                                "description": "backlog | in_progress | review | done"]
        return [
            tool("board", "Обзор проекта: активные агенты и что они делают, открытые задачи, недавние коммиты и заметки.", [:], readOnly: true),
            tool("agent_activity", "Что делает другой агент: его запрос, команды, изменённые файлы, коммиты, последний ответ. Без agent — краткий обзор всех агентов проекта.",
                 ["agent": prop("string", "Имя агента (например «Вега») или его agent_id"),
                  "limit": prop("integer", "Сколько последних событий показать (по умолчанию 30)")], readOnly: true),
            tool("list_tasks", "Список задач проекта.",
                 ["status": statusEnum, "client": prop("string", "Фильтр по клиенту"),
                  "include_done": prop("boolean", "Включить завершённые")], readOnly: true),
            tool("create_task", "Создать задачу на общей доске. claim=true — сразу взять её себе.",
                 ["title": prop("string", "Короткое название"), "details": prop("string", "Подробности"),
                  "client": prop("string", "Клиент, для которого работа (если есть)"), "status": statusEnum,
                  "claim": prop("boolean", "Сразу взять задачу себе")], ["title"]),
            tool("claim_task", "Взять задачу себе. Откажет, если её уже делает другой активный агент (force=true — забрать).",
                 ["task_id": prop("integer", "Номер задачи"), "force": prop("boolean", "Забрать у другого агента")], ["task_id"]),
            tool("update_task", "Обновить задачу: статус, итог работы (note), клиент.",
                 ["task_id": prop("integer", "Номер задачи"), "status": statusEnum,
                  "note": prop("string", "Что сделано / что осталось"), "client": prop("string", "Клиент"),
                  "release": prop("boolean", "Снять себя с задачи")], ["task_id"]),
            tool("set_focus", "Объявить, над чем ты сейчас работаешь и какие файлы трогаешь.",
                 ["focus": prop("string", "Над чем работаешь"),
                  "files": ["type": "array", "items": ["type": "string"], "description": "Пути файлов относительно корня репозитория"]],
                 ["focus"]),
            tool("send_message", "Написать сообщение другому агенту (оно придёт в его контекст) или всем агентам проекта.",
                 ["to": prop("string", "Имя агента, его agent_id или \"all\""), "text": prop("string", "Текст сообщения")], ["to", "text"]),
            tool("post_note", "Заметка в ленту проекта для человека и других агентов (решение, предупреждение, итог).",
                 ["text": prop("string", "Текст заметки"), "client": prop("string", "Клиент, если заметка о нём")], ["text"]),
            tool("who_touches", "Кто из агентов недавно менял файл.", ["path": prop("string", "Путь файла")], ["path"], readOnly: true),
            tool("register_agent", "Зарегистрироваться на панели (для клиентов без хуков, например Codex). Вернёт agent_id.",
                 ["cwd": prop("string", "Абсолютный путь текущей рабочей папки"),
                  "tool": prop("string", "codex, cursor, …"), "name": prop("string", "Желаемое имя")], ["cwd"]),
        ]
    }

    func handleMCP(_ body: Data) -> Data? {
        guard let parsed = parseJSON(body) else {
            return jsonData(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = parsed as? [JSON] {
            let results = batch.compactMap { mcpOne($0) }
            return results.isEmpty ? nil : jsonData(results)
        }
        guard let msg = parsed as? JSON else { return nil }
        return mcpOne(msg).map(jsonData)
    }

    private func mcpOne(_ msg: JSON) -> JSON? {
        guard let id = msg["id"], !(id is NSNull) else { return nil } // notification
        let method = msg.s("method")
        let params = msg["params"] as? JSON ?? [:]
        func ok(_ result: Any) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            return ok([
                "protocolVersion": params.str("protocolVersion") ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "agentboard", "title": "AgentBoard", "version": AppInfo.version],
                "instructions": Self.mcpInstructions,
            ])
        case "ping":
            return ok([:] as JSON)
        case "tools/list":
            return ok(["tools": Self.toolDefs])
        case "resources/list":
            return ok(["resources": [] as [Any]])
        case "prompts/list":
            return ok(["prompts": [] as [Any]])
        case "tools/call":
            let name = params.s("name")
            let args = params["arguments"] as? JSON ?? [:]
            let (text, isError) = callTool(name, args)
            changed()
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    private func callTool(_ name: String, _ args: JSON) -> (String, Bool) {
        // Who is calling?
        var me: Agent?
        if let aid = args.str("agent_id") { me = findAgent(aid, project: nil) }
        if me == nil { me = agentForMCPCall(tool: name, args: args) }
        var project: Project? = me.flatMap { self.project(id: $0.projectId) }
        if project == nil, let p = args.str("project_path") ?? args.str("cwd") { project = projectFor(cwd: p) }
        if project == nil { let all = allProjects(); if all.count == 1 { project = all[0] } }
        if let me { setAgent(me.id, ["last_seen": now()]) }

        if name == "register_agent" {
            let cwd = args.s("cwd")
            guard let p = projectFor(cwd: cwd) ?? project else {
                return ("Папка \(cwd) не относится ни к одному проекту AgentBoard. Человек должен добавить проект в приложении.", true)
            }
            let tool = args.str("tool") ?? "codex"
            // Codex sessions are already followed from their logs: reuse that agent instead of creating a twin.
            if let existing = agents(project: p.id).first(where: {
                $0.tool == tool && $0.status != "ended" && now() - $0.lastSeen < 600 && ($0.cwd == cwd || cwd.hasPrefix($0.cwd + "/"))
            }) {
                return ("Твой agent_id: \(existing.id) (имя «\(existing.name)»). Передавай его во все вызовы agentboard.\n\n"
                        + boardText(project: p, me: existing, includeRules: true), false)
            }
            let a = touchAgent(tool: tool, sessionId: "mcp-" + UUID().uuidString, project: p, cwd: cwd.isEmpty ? p.path : cwd,
                               transcript: nil, revive: true, name: args.str("name"))
            setAgent(a.id, ["status": "working", "last_action": "зарегистрировался"])
            addEvent(project: p.id, agent: a.id, kind: "session_start", title: "\(a.name) подключился (\(a.toolLabel))", detail: cwd)
            return ("Твой agent_id: \(a.id) (имя «\(a.name)»). Передавай его во все вызовы agentboard.\n\n"
                    + boardText(project: p, me: a, includeRules: true), false)
        }

        guard let project else {
            return ("Не удалось определить проект. Передай agent_id (из register_agent) или project_path.", true)
        }
        // Messages for the caller ride along with any tool result (main delivery path for Codex).
        let inbox = me.flatMap { takeInbox(agent: $0.id) }
        func done(_ text: String, _ err: Bool = false) -> (String, Bool) {
            (inbox.map { text + "\n\n" + $0 } ?? text, err)
        }

        switch name {
        case "board":
            return done(boardText(project: project, me: me, includeRules: false))

        case "agent_activity":
            if let key = args.str("agent") {
                guard let a = findAgent(key, project: project.id) else {
                    let names = agents(project: project.id).prefix(15).map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")
                    return done("Агент «\(key)» не найден. Известные агенты: \(names.isEmpty ? "нет" : names)", true)
                }
                let limit = Int(args.oi("limit") ?? 30)
                return done(activityText(a, limit: max(5, min(limit, 150))))
            }
            let list = agents(project: project.id).filter { $0.id != me?.id }.prefix(12)
            if list.isEmpty { return done("Других агентов в проекте нет.") }
            return done(list.map(describe).joined(separator: "\n")
                        + "\n\nПодробнее об агенте: agent_activity(agent: \"имя\").")

        case "list_tasks":
            var items = tasks(project: project.id, includeDone: args.b("include_done"))
            if let st = args.str("status") { items = items.filter { $0.status.rawValue == st } }
            if let c = args.str("client") { items = items.filter { $0.client.localizedCaseInsensitiveContains(c) } }
            if items.isEmpty { return done("Задач нет.") }
            return done(items.prefix(60).map { t in
                let who = t.assignee.flatMap { agent(id: $0)?.name } ?? "свободна"
                var s = "#\(t.id) [\(t.status.label), \(who)\(t.client.isEmpty ? "" : ", клиент: \(t.client)")] \(t.title)"
                if !t.details.isEmpty { s += "\n   " + t.details.oneLine.trunc(300) }
                return s
            }.joined(separator: "\n"))

        case "create_task":
            guard let title = args.str("title") else { return done("Нужен title", true) }
            let claim = args.b("claim") && me != nil
            var status = TaskStatus(rawValue: args.s("status")) ?? .backlog
            if claim && status == .backlog { status = .in_progress }
            let t = createTask(project: project.id, title: title, details: args.s("details"),
                               client: args.str("client") ?? project.client, status: status,
                               assignee: claim ? me?.id : nil, createdBy: me?.id ?? "agent")
            if claim, let me, me.focus.isEmpty { setAgent(me.id, ["focus": title]) }
            return done("Создана задача #\(t.id) «\(t.title)» (\(t.status.label))\(claim ? ", взята тобой" : "").")

        case "claim_task":
            guard let me else { return done("Не знаю, кто ты. Передай agent_id (register_agent).", true) }
            guard let tid = args.oi("task_id"), let t = task(id: tid), t.projectId == project.id else {
                return done("Задача не найдена", true)
            }
            if let owner = t.assignee, owner != me.id, let oa = agent(id: owner),
               oa.isActive(staleMinutes: AppSettings.staleMinutes), !args.b("force") {
                return done("Задачу #\(tid) уже делает \(oa.name) (активен). Выбери другую задачу или договорись через send_message.", true)
            }
            updateTask(tid, status: t.status == .backlog ? .in_progress : nil, assignee: .some(me.id), by: me.id)
            setAgent(me.id, ["focus": t.title])
            return done("Задача #\(tid) «\(t.title)» теперь твоя.\(t.details.isEmpty ? "" : "\nОписание: \(t.details)")")

        case "update_task":
            guard let tid = args.oi("task_id"), let t = task(id: tid), t.projectId == project.id else {
                return done("Задача не найдена", true)
            }
            var status: TaskStatus?
            if let s = args.str("status") {
                guard let st = TaskStatus(rawValue: s) else { return done("Неизвестный статус \(s)", true) }
                status = st
            }
            let assignee: String?? = args.b("release") ? .some(nil) : nil
            updateTask(tid, client: args.str("client"), status: status, assignee: assignee, by: me?.id)
            if let note = args.str("note") {
                addEvent(project: project.id, agent: me?.id, kind: "note",
                         title: "#\(tid) «\(t.title.trunc(80))»: \(note.oneLine.trunc(200))", detail: note,
                         client: args.str("client") ?? t.client, ref: "\(tid)")
            }
            if let me, status == .done || status == .review, me.focus == t.title { setAgent(me.id, ["focus": ""]) }
            return done("Задача #\(tid) обновлена.")

        case "set_focus":
            guard let me else { return done("Не знаю, кто ты. Передай agent_id (register_agent).", true) }
            let focus = args.s("focus")
            setAgent(me.id, ["focus": focus.trunc(500)])
            let files = (args["files"] as? [String]) ?? []
            var warnings: [String] = []
            for f in files {
                touchFile(agent: me, path: f)
                let others = othersTouching(path: f, project: project.id, except: me.id)
                if !others.isEmpty { warnings.append("\(f) — недавно менял(и) \(others.map { $0.name }.joined(separator: ", "))") }
            }
            addEvent(project: project.id, agent: me.id, kind: "focus", title: "\(me.name): \(focus.oneLine.trunc(200))",
                     detail: files.joined(separator: "\n"))
            return done("Фокус записан." + (warnings.isEmpty ? "" : "\nВнимание, возможны пересечения:\n" + warnings.joined(separator: "\n")))

        case "send_message":
            guard let text = args.str("text") else { return done("Нужен text", true) }
            let to = args.s("to")
            if to.isEmpty || ["all", "все", "всем", "*"].contains(to.lowercased()) {
                let n = sendMessage(project: project.id, to: nil, from: me, text: text)
                return done(n == 0 ? "Других активных агентов нет — сообщение записано в ленту." : "Отправлено \(n) агент(ам).")
            }
            guard let target = findAgent(to, project: project.id) else { return done("Агент «\(to)» не найден", true) }
            sendMessage(project: project.id, to: target.id, from: me, text: text)
            let st = target.displayStatus(staleMinutes: AppSettings.staleMinutes)
            let hint = st == .working ? "получит его при следующем действии"
                : "сейчас \(st.label); получит, когда человек снова напишет ему или он вызовет agentboard"
            return done("Сообщение для \(target.name) поставлено в очередь — \(hint).")

        case "post_note":
            guard let text = args.str("text") else { return done("Нужен text", true) }
            addEvent(project: project.id, agent: me?.id, kind: "note",
                     title: "\(me?.name ?? "Агент"): \(text.oneLine.trunc(200))", detail: text, client: args.s("client"))
            return done("Заметка добавлена в ленту.")

        case "who_touches":
            let path = args.s("path")
            let rel = me.map { relativePath(path, agent: $0, project: project) } ?? path
            let rows = db.query("SELECT * FROM file_touches WHERE project_id=? AND (path=? OR path LIKE ?) ORDER BY last_at DESC LIMIT 10",
                                [project.id, rel, "%" + rel]).map(FileTouch.init)
            if rows.isEmpty { return done("Никто из агентов не трогал \(rel) за последнее время.") }
            return done(rows.map { f in
                let a = agent(id: f.agentId)
                return "- \(a?.name ?? f.agentId) (\(a?.displayStatus(staleMinutes: AppSettings.staleMinutes).label ?? "?")): \(f.path), ×\(f.count), \(Fmt.rel(f.lastAt))"
            }.joined(separator: "\n"))

        default:
            return done("Неизвестный инструмент \(name)", true)
        }
    }
}
