import Foundation

/// The brain of AgentBoard: database, hook handling, coordination rules.
/// Every method that touches `db` or in-memory state must run on `q`.
final class Core {
    static let shared = Core()

    let q = DispatchQueue(label: "agentboard.core")
    private(set) var db: Database!
    let supportDir: URL

    private var cwdCache: [String: (projectId: String?, at: Double)] = [:]
    private struct PendingEntry {
        var commit: PendingCommit
        var reply: (Data?) -> Void
        var timer: DispatchWorkItem
    }
    private var pending: [String: PendingEntry] = [:]
    private var mcpCalls: [(agentId: String, tool: String, args: String, at: Double)] = []
    private var lastInjected: [String: String] = [:]
    private var conflictSeen: [String: Double] = [:]

    var onChange: (() -> Void)?
    var notify: ((String, String) -> Void)?

    /// 100 superhero names for agents; the first free one is given to each new session.
    static let heroNames = [
        "Бэтмен", "Супермен", "Чудо-женщина", "Флэш", "Аквамен", "Киборг", "Зелёный Фонарь", "Зелёная Стрела",
        "Чёрная Канарейка", "Марсианский Охотник", "Шазам", "Синий Жук", "Бустер Голд", "Затанна", "Константин", "Рейвен",
        "Старфайр", "Бист Бой", "Хокмэн", "Хокгёрл", "Атом", "Огненный Шторм", "Супергёрл", "Найтвинг",
        "Робин", "Бэтгёрл", "Бэтвумен", "Женщина-кошка", "Чёрная Молния", "Стальной", "Железный Человек", "Капитан Америка",
        "Тор", "Халк", "Чёрная Вдова", "Соколиный Глаз", "Человек-паук", "Доктор Стрэндж", "Чёрная Пантера", "Капитан Марвел",
        "Сокол", "Зимний Солдат", "Алая Ведьма", "Вижн", "Человек-муравей", "Оса", "Росомаха", "Циклоп",
        "Шторм", "Джин Грей", "Зверь", "Ночной Змей", "Колосс", "Роуг", "Гамбит", "Псайлок",
        "Китти Прайд", "Бишоп", "Кейбл", "Дэдпул", "Сорвиголова", "Каратель", "Люк Кейдж", "Железный Кулак",
        "Джессика Джонс", "Лунный Рыцарь", "Призрачный Гонщик", "Блэйд", "Серебряный Сёрфер", "Мистер Фантастик", "Невидимая Леди", "Человек-факел",
        "Существо", "Нова", "Звёздный Лорд", "Гамора", "Дракс", "Ракета", "Грут", "Мантис",
        "Мисс Марвел", "Шан-Чи", "Женщина-Халк", "Воитель", "Ник Фьюри", "Агент Картер", "Ртуть", "Ангел",
        "Ледяной Человек", "Полярис", "Хавок", "Банши", "Магик", "Женщина-паук", "Майлз Моралес", "Эхо",
        "Кейт Бишоп", "Икс-23", "Сентри", "Геркулес",
    ]

    init() {
        if let dir = ProcessInfo.processInfo.environment["AGENTBOARD_DATA_DIR"], !dir.isEmpty {
            supportDir = URL(fileURLWithPath: dir)
        } else {
            supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentBoard")
        }
    }

    func setup() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        db = try Database(path: supportDir.appendingPathComponent("agentboard.sqlite").path)
        migrate()
    }

    private func migrate() {
        db.exec("""
        CREATE TABLE IF NOT EXISTS projects(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE, common_dir TEXT DEFAULT '',
          client TEXT DEFAULT '', created_at REAL);
        CREATE TABLE IF NOT EXISTS agents(
          id TEXT PRIMARY KEY, project_id TEXT, tool TEXT, session_id TEXT, name TEXT, cwd TEXT DEFAULT '',
          root TEXT DEFAULT '', branch TEXT DEFAULT '', status TEXT DEFAULT 'idle', last_prompt TEXT DEFAULT '',
          focus TEXT DEFAULT '', last_action TEXT DEFAULT '', last_action_at REAL DEFAULT 0, started_at REAL,
          last_seen REAL, ended_at REAL, transcript_path TEXT DEFAULT '');
        CREATE INDEX IF NOT EXISTS agents_session ON agents(tool, session_id);
        CREATE TABLE IF NOT EXISTS tasks(
          id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT, title TEXT, details TEXT DEFAULT '',
          client TEXT DEFAULT '', status TEXT DEFAULT 'backlog', assignee TEXT, created_by TEXT DEFAULT '',
          created_at REAL, updated_at REAL, done_at REAL);
        CREATE TABLE IF NOT EXISTS events(
          id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT, agent_id TEXT, kind TEXT, title TEXT,
          detail TEXT DEFAULT '', client TEXT DEFAULT '', ref TEXT DEFAULT '', created_at REAL);
        CREATE INDEX IF NOT EXISTS events_time ON events(created_at);
        CREATE INDEX IF NOT EXISTS events_project_time ON events(project_id, created_at);
        CREATE TABLE IF NOT EXISTS file_touches(
          agent_id TEXT, project_id TEXT, path TEXT, count INTEGER DEFAULT 0, last_at REAL,
          PRIMARY KEY(agent_id, path));
        CREATE TABLE IF NOT EXISTS messages(
          id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT, to_agent TEXT, from_agent TEXT,
          from_label TEXT DEFAULT '', text TEXT, created_at REAL, delivered_at REAL);
        CREATE TABLE IF NOT EXISTS codex_offsets(path TEXT PRIMARY KEY, offset INTEGER);
        CREATE TABLE IF NOT EXISTS summaries(
          id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT, markdown TEXT, source TEXT DEFAULT '', created_at REAL);
        """)
        let cols = Set(db.query("PRAGMA table_info(agents)").map { $0.s("name") })
        HistoryImporter.ensureSchema(self)
        let pcols = Set(db.query("PRAGMA table_info(projects)").map { $0.s("name") })
        if !pcols.contains("aliases") { db.exec("ALTER TABLE projects ADD COLUMN aliases TEXT DEFAULT ''") }
        if !cols.contains("tty") { db.exec("ALTER TABLE agents ADD COLUMN tty TEXT DEFAULT ''") }
    }

    func changed() { onChange?() }

    // MARK: - Snapshot for UI

    struct Snapshot {
        var projects: [Project]
        var agents: [Agent]
        var tasks: [TaskItem]
        var events: [EventItem]
        var files: [FileTouch]
        var summaries: [SummaryItem]
        var pending: [PendingCommit]
        var messages: [MessageItem]
        var lastWork: [String: Double]
    }

    func snapshot() -> Snapshot {
        let weekAgo = now() - 7 * 86400
        return Snapshot(
            projects: allProjects(),
            agents: db.query("SELECT * FROM agents WHERE last_seen > ? OR ended_at IS NULL ORDER BY last_seen DESC",
                             [weekAgo]).map(Agent.init),
            tasks: db.query("SELECT * FROM tasks WHERE status != 'done' OR done_at > ? ORDER BY updated_at DESC",
                            [now() - 30 * 86400]).map(TaskItem.init),
            events: db.query("SELECT * FROM events WHERE created_at > ? ORDER BY created_at DESC, id DESC LIMIT 3000",
                             [weekAgo]).map(EventItem.init),
            files: db.query("SELECT * FROM file_touches WHERE last_at > ? ORDER BY last_at DESC",
                            [now() - 2 * 86400]).map(FileTouch.init),
            summaries: db.query("SELECT * FROM summaries ORDER BY day DESC, id DESC LIMIT 400").map(SummaryItem.init),
            pending: pending.values.map(\.commit).sorted { $0.createdAt < $1.createdAt },
            messages: db.query("SELECT * FROM messages WHERE created_at > ? ORDER BY id DESC LIMIT 500",
                               [weekAgo]).map(MessageItem.init),
            lastWork: Dictionary(uniqueKeysWithValues: db.query("""
                SELECT project_id, MAX(created_at) AS t FROM events
                WHERE kind IN ('prompt','action','commit','turn_done') GROUP BY project_id
                """).map { ($0.s("project_id"), $0.d("t")) })
        )
    }

    // MARK: - History (any past day, read straight from the database)

    struct DayActivity: Identifiable, Hashable {
        var day: String
        var events: Int
        var agents: Int
        var id: String { day }
    }

    struct History {
        var agents: [Agent]
        var events: [EventItem]
        var tasksDone: [TaskItem]
    }

    func activeDays(limit: Int = 120) -> [DayActivity] {
        db.query("""
            SELECT date(created_at, 'unixepoch', 'localtime') AS day, COUNT(*) AS n, COUNT(DISTINCT agent_id) AS a
            FROM events GROUP BY day ORDER BY day DESC LIMIT ?
            """, [limit]).map { DayActivity(day: $0.s("day"), events: Int($0.i("n")), agents: Int($0.i("a"))) }
    }

    func history(from: Double, to: Double, project: String?) -> History {
        var sql = "SELECT * FROM events WHERE created_at >= ? AND created_at < ?"
        var args: [Any] = [from, to]
        if let project { sql += " AND project_id = ?"; args.append(project) }
        let events = db.query(sql + " ORDER BY id", args).map(EventItem.init)
        let ids = Array(Set(events.compactMap(\.agentId)))
        let agents = ids.compactMap { agent(id: $0) }
        var tsql = "SELECT * FROM tasks WHERE done_at >= ? AND done_at < ?"
        var targs: [Any] = [from, to]
        if let project { tsql += " AND project_id = ?"; targs.append(project) }
        return History(agents: agents, events: events, tasksDone: db.query(tsql, targs).map(TaskItem.init))
    }

    // MARK: - Projects

    func allProjects() -> [Project] {
        db.query("SELECT * FROM projects ORDER BY name COLLATE NOCASE").map(Project.init)
    }

    func project(id: String) -> Project? {
        db.query("SELECT * FROM projects WHERE id=?", [id]).first.map(Project.init)
    }

    func addProject(path rawPath: String) -> Result<Project, ProjectError> {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
        let top = Shell.git(["rev-parse", "--show-toplevel"], cwd: path)
        let root = top.ok ? top.line : path
        if let existing = allProjects().first(where: { $0.path == root }) {
            return .failure(ProjectError(message: "Проект «\(existing.name)» уже добавлен"))
        }
        let common = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: root)
        // A linked worktree of a known project belongs to that project.
        if common.ok, let owner = allProjects().first(where: { $0.commonDir == common.line }) {
            return .failure(ProjectError(message: "Это рабочая копия (worktree) проекта «\(owner.name)» — она уже отслеживается"))
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let name = URL(fileURLWithPath: root).lastPathComponent
        db.query("INSERT INTO projects(id, name, path, common_dir, client, created_at) VALUES(?,?,?,?,?,?)",
                 [id, name, root, common.ok ? common.line : "", "", now()])
        cwdCache.removeAll()
        changed()
        return .success(project(id: id)!)
    }

    struct ProjectError: Error { let message: String }

    func updateProject(id: String, name: String, client: String) {
        db.update("projects", id: id, ["name": name, "client": client])
        changed()
    }

    func removeProject(id: String) {
        for t in ["agents", "tasks", "events", "file_touches", "messages"] {
            db.query("DELETE FROM \(t) WHERE project_id=?", [id])
        }
        db.query("DELETE FROM projects WHERE id=?", [id])
        db.query("DELETE FROM imported_sessions WHERE project_id=?", [id])
        cwdCache.removeAll()
        changed()
    }

    func projectFor(cwd: String) -> Project? {
        guard !cwd.isEmpty else { return nil }
        let t = now()
        if let c = cwdCache[cwd], t - c.at < 120 {
            return c.projectId.flatMap { project(id: $0) }
        }
        let projects = allProjects().sorted { $0.path.count > $1.path.count }
        var found = projects.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }
        if found == nil, FileManager.default.fileExists(atPath: cwd) {
            let r = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: cwd, timeout: 5)
            if r.ok { found = projects.first { !$0.commonDir.isEmpty && $0.commonDir == r.line } }
        }
        cwdCache[cwd] = (found?.id, t)
        return found
    }

    // MARK: - Agents

    func agent(id: String) -> Agent? {
        db.query("SELECT * FROM agents WHERE id=?", [id]).first.map(Agent.init)
    }

    func agents(project: String) -> [Agent] {
        db.query("SELECT * FROM agents WHERE project_id=? ORDER BY last_seen DESC", [project]).map(Agent.init)
    }

    func activeAgents(project: String) -> [Agent] {
        agents(project: project).filter { $0.isActive(staleMinutes: AppSettings.staleMinutes) }
    }

    private func pickName(project: String) -> String {
        let used = Set(agents(project: project).filter { $0.status != "ended" }.map(\.name))
        if let n = Self.heroNames.first(where: { !used.contains($0) }) { return n }
        var i = 2
        while true {
            for n in Self.heroNames where !used.contains("\(n)-\(i)") { return "\(n)-\(i)" }
            i += 1
        }
    }

    private func uniqueAgentId(tool: String, seed: String) -> String {
        let base = tool + "-" + String(seed.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
        var id = base
        var n = 2
        while agent(id: id) != nil { id = "\(base)\(n)"; n += 1 }
        return id
    }

    /// Finds or creates the agent for a session and marks it as seen.
    func touchAgent(tool: String, sessionId: String, project: Project, cwd: String,
                    transcript: String?, revive: Bool, name: String? = nil) -> Agent {
        let t = now()
        if let a = db.query("SELECT * FROM agents WHERE tool=? AND session_id=?", [tool, sessionId]).first.map(Agent.init) {
            var f: [String: Any] = ["last_seen": t, "project_id": project.id]
            if !cwd.isEmpty && cwd != a.cwd {
                f["cwd"] = cwd
                let top = Shell.git(["rev-parse", "--show-toplevel"], cwd: cwd, timeout: 5)
                f["root"] = top.ok ? top.line : cwd
            }
            if revive && a.status == "ended" { f["status"] = "idle"; f["ended_at"] = NSNull() }
            if let transcript, !transcript.isEmpty, transcript != a.transcriptPath { f["transcript_path"] = transcript }
            db.update("agents", id: a.id, f)
            return agent(id: a.id)!
        }
        let top = Shell.git(["rev-parse", "--show-toplevel"], cwd: cwd, timeout: 5)
        let branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd, timeout: 5)
        let id = uniqueAgentId(tool: tool, seed: sessionId)
        db.query("""
            INSERT INTO agents(id, project_id, tool, session_id, name, cwd, root, branch, status, started_at, last_seen,
                               last_action_at, transcript_path)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [id, project.id, tool, sessionId, name ?? pickName(project: project.id), cwd,
                  top.ok ? top.line : cwd, branch.ok ? branch.line : "", "idle", t, t, t, transcript ?? ""])
        return agent(id: id)!
    }

    func setAgent(_ id: String, _ f: [String: Any]) {
        var fields = f
        if fields["last_action"] != nil { fields["last_action_at"] = now() }
        db.update("agents", id: id, fields)
    }

    func renameAgent(_ id: String, to name: String) {
        guard !name.trimmed.isEmpty else { return }
        setAgent(id, ["name": name.trimmed])
        changed()
    }

    func endAgent(_ id: String) {
        setAgent(id, ["status": "ended", "ended_at": now()])
        changed()
    }

    func purgeEndedAgents(project: String) {
        // Agents with recorded work are kept: the history needs their names.
        db.query("""
            DELETE FROM agents WHERE project_id=? AND (status='ended' OR last_seen < ?)
              AND id NOT IN (SELECT agent_id FROM events WHERE agent_id IS NOT NULL AND kind IN ('prompt','action','commit'))
            """,
                 [project, now() - AppSettings.staleMinutes * 60])
        changed()
    }

    // MARK: - Events, files

    @discardableResult
    func addEvent(project: String, agent: String?, kind: String, title: String, detail: String = "",
                  client: String = "", ref: String = "") -> Int64 {
        db.query("INSERT INTO events(project_id, agent_id, kind, title, detail, client, ref, created_at) VALUES(?,?,?,?,?,?,?,?)",
                 [project, nn(agent), kind, title.trunc(300), detail.trunc(8000), client, ref, now()])
        return db.lastInsertId
    }

    /// Raw activity (commands, edits). Hidden from the feed by default, used by agent_activity and summaries.
    func addAction(agent: Agent, title: String, detail: String) {
        let last = db.query("SELECT title FROM events WHERE agent_id=? ORDER BY id DESC LIMIT 1", [agent.id]).first?.s("title")
        if last == title { return }
        addEvent(project: agent.projectId, agent: agent.id, kind: "action", title: title, detail: detail.trimmed)
    }

    func touchFile(agent: Agent, path: String) {
        guard !path.isEmpty else { return }
        db.query("""
            INSERT INTO file_touches(agent_id, project_id, path, count, last_at) VALUES(?,?,?,1,?)
            ON CONFLICT(agent_id, path) DO UPDATE SET count = count + 1, last_at = excluded.last_at
            """, [agent.id, agent.projectId, path, now()])
    }

    func relativePath(_ path: String, agent: Agent, project: Project) -> String {
        for base in [agent.root, project.path, agent.cwd] where !base.isEmpty {
            if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        }
        return path
    }

    /// Other active agents that touched the file in the last `window` seconds.
    func othersTouching(path: String, project: String, except agentId: String, window: Double = 1800) -> [Agent] {
        let rows = db.query("SELECT agent_id FROM file_touches WHERE project_id=? AND path=? AND agent_id != ? AND last_at > ?",
                            [project, path, agentId, now() - window])
        return rows.compactMap { agent(id: $0.s("agent_id")) }.filter { $0.isActive(staleMinutes: AppSettings.staleMinutes) }
    }

    func recentFiles(agent: String, limit: Int = 8) -> [String] {
        db.query("SELECT path FROM file_touches WHERE agent_id=? ORDER BY last_at DESC LIMIT ?", [agent, limit]).map { $0.s("path") }
    }

    // MARK: - Messages (inbox for agents) and activity of other agents

    /// Finds an agent by id or by name (case-insensitive), preferring active ones in the given project.
    func findAgent(_ key: String, project: String?) -> Agent? {
        let k = key.trimmed
        guard !k.isEmpty else { return nil }
        if let a = agent(id: k) { return a }
        // SQLite NOCASE only folds ASCII, so compare Cyrillic names in Swift.
        let needle = k.lowercased().replacingOccurrences(of: "ё", with: "е")
        let rows = db.query("SELECT * FROM agents ORDER BY last_seen DESC LIMIT 2000").map(Agent.init).filter {
            $0.name.lowercased().replacingOccurrences(of: "ё", with: "е") == needle
        }
        if let project, let a = rows.first(where: { $0.projectId == project }) { return a }
        return rows.first
    }

    /// to == nil → broadcast to every active agent of the project (except the sender).
    @discardableResult
    func sendMessage(project: String, to: String?, from: Agent?, text: String) -> Int {
        let targets: [String] = to.map { [$0] }
            ?? activeAgents(project: project).map(\.id).filter { $0 != from?.id }
        let label = from.map { "\($0.name) [\($0.id)]" } ?? "Человек (панель AgentBoard)"
        for t in targets {
            db.query("INSERT INTO messages(project_id, to_agent, from_agent, from_label, text, created_at) VALUES(?,?,?,?,?,?)",
                     [project, t, nn(from?.id), label, text, now()])
        }
        let toLabel = to.flatMap { agent(id: $0)?.name } ?? "всем агентам"
        addEvent(project: project, agent: from?.id, kind: "message",
                 title: "\(from?.name ?? "Вы") → \(toLabel): \(text.oneLine.trunc(160))", detail: text)
        changed()
        return targets.count
    }

    /// Returns undelivered messages for the agent formatted for its context, and marks them delivered.
    func takeInbox(agent: String) -> String? {
        let rows = db.query("SELECT * FROM messages WHERE to_agent=? AND delivered_at IS NULL ORDER BY id", [agent]).map(MessageItem.init)
        guard !rows.isEmpty else { return nil }
        db.query("UPDATE messages SET delivered_at=? WHERE to_agent=? AND delivered_at IS NULL", [now(), agent])
        changed()
        let body = rows.map { "- от \($0.fromLabel) (\(Fmt.time($0.createdAt))): \($0.text)" }.joined(separator: "\n")
        return "[AgentBoard] Новые сообщения для тебя:\n\(body)\nУчти их в работе. Ответить можно через send_message(to, text)."
    }

    /// Detailed recent activity of an agent: for "посмотри, что делает соседний агент".
    func activityText(_ a: Agent, limit: Int = 30) -> String {
        var out: [String] = []
        let st = a.displayStatus(staleMinutes: AppSettings.staleMinutes)
        out.append("Агент \(a.name) [\(a.id)], \(a.toolLabel). Статус: \(st.label), последняя активность \(Fmt.rel(a.lastSeen)).")
        out.append("Рабочая папка: \(a.cwd)" + (a.branch.isEmpty ? "" : ", ветка \(a.branch)"))
        if !a.focus.isEmpty { out.append("Фокус: \(a.focus)") }
        if let t = db.query("SELECT * FROM tasks WHERE assignee=? AND status != 'done' ORDER BY updated_at DESC LIMIT 3", [a.id]).first.map(TaskItem.init) {
            out.append("Задача: #\(t.id) «\(t.title)» (\(t.status.label))\(t.details.isEmpty ? "" : " — \(t.details.trunc(400))")")
        }
        if !a.lastPrompt.isEmpty { out.append("Последний запрос человека к нему:\n«\(a.lastPrompt.trunc(1500))»") }
        let files = db.query("SELECT path, count, last_at FROM file_touches WHERE agent_id=? ORDER BY last_at DESC LIMIT 20", [a.id])
        if !files.isEmpty {
            out.append("Файлы, которые он менял: " + files.map { "\($0.s("path")) (×\($0.i("count")), \(Fmt.time($0.d("last_at"))))" }.joined(separator: ", "))
        }
        let events = db.query("SELECT * FROM events WHERE agent_id=? ORDER BY created_at DESC, id DESC LIMIT ?", [a.id, limit]).map(EventItem.init)
        if !events.isEmpty {
            out.append("Хронология (новые сверху):")
            for e in events {
                var line = "- \(Fmt.time(e.createdAt)) [\(e.kind)] \(e.title.oneLine.trunc(220))"
                if e.kind == "commit" || e.kind == "note" { line += e.detail.isEmpty ? "" : "\n  " + e.detail.oneLine.trunc(300) }
                out.append(line)
            }
        }
        let answer = db.query("SELECT detail FROM events WHERE agent_id=? AND kind='turn_done' AND detail != '' ORDER BY created_at DESC, id DESC LIMIT 1", [a.id])
        if let d = answer.first?.s("detail") { out.append("Его последний ответ:\n\(d.trunc(2000))") }
        return out.joined(separator: "\n")
    }

    // MARK: - Tasks

    func task(id: Int64) -> TaskItem? {
        db.query("SELECT * FROM tasks WHERE id=?", [id]).first.map(TaskItem.init)
    }

    func tasks(project: String, includeDone: Bool = false) -> [TaskItem] {
        let sql = includeDone
            ? "SELECT * FROM tasks WHERE project_id=? ORDER BY updated_at DESC"
            : "SELECT * FROM tasks WHERE project_id=? AND status != 'done' ORDER BY updated_at DESC"
        return db.query(sql, [project]).map(TaskItem.init)
    }

    @discardableResult
    func createTask(project: String, title: String, details: String, client: String, status: TaskStatus,
                    assignee: String?, createdBy: String) -> TaskItem {
        let t = now()
        db.query("""
            INSERT INTO tasks(project_id, title, details, client, status, assignee, created_by, created_at, updated_at, done_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [project, title, details, client, status.rawValue, nn(assignee), createdBy, t, t,
                  status == .done ? t : NSNull()])
        let task = self.task(id: db.lastInsertId)!
        addEvent(project: project, agent: assignee ?? (createdBy == "user" ? nil : createdBy), kind: "task_created",
                 title: "Задача #\(task.id): \(title)", detail: details, client: client, ref: "\(task.id)")
        if createdBy == "user", let to = assignee {
            sendMessage(project: project, to: to, from: nil,
                        text: "Тебе назначена новая задача #\(task.id) «\(title)»\(client.isEmpty ? "" : " (клиент: \(client))").\(details.isEmpty ? "" : " Описание: \(details)") Отчитайся через update_task.")
        }
        changed()
        return task
    }

    func updateTask(_ id: Int64, title: String? = nil, details: String? = nil, client: String? = nil,
                    status: TaskStatus? = nil, assignee: String?? = nil, by actor: String? = nil) {
        guard let old = task(id: id) else { return }
        var f: [String: Any] = ["updated_at": now()]
        if let title { f["title"] = title }
        if let details { f["details"] = details }
        if let client { f["client"] = client }
        if let status {
            f["status"] = status.rawValue
            f["done_at"] = status == .done ? now() : NSNull()
        }
        if let assignee { f["assignee"] = nn(assignee) }
        db.update("tasks", id: id, f)
        let who = actor.flatMap { agent(id: $0)?.name } ?? "Вы"
        if let status, status != old.status {
            addEvent(project: old.projectId, agent: actor, kind: "task_status",
                     title: "\(who): #\(id) «\(old.title)» → \(status.label)", client: client ?? old.client, ref: "\(id)")
        }
        if let assignee, assignee != old.assignee {
            let name = assignee.flatMap { agent(id: $0)?.name } ?? "никто"
            addEvent(project: old.projectId, agent: assignee ?? actor, kind: "task_claimed",
                     title: "#\(id) «\(old.title)» → исполнитель: \(name)", client: client ?? old.client, ref: "\(id)")
        }
        // The human assigned a task from the panel: tell the agent.
        if actor == nil, let assignee, let to = assignee, to != old.assignee {
            let t = task(id: id) ?? old
            sendMessage(project: old.projectId, to: to, from: nil,
                        text: "Тебе назначена задача #\(id) «\(t.title)»\(t.client.isEmpty ? "" : " (клиент: \(t.client))").\(t.details.isEmpty ? "" : " Описание: \(t.details)") Когда закончишь текущее — возьми её (claim_task) и отчитайся через update_task.")
        }
        changed()
    }

    func deleteTask(_ id: Int64) {
        db.query("DELETE FROM tasks WHERE id=?", [id])
        changed()
    }

    // MARK: - Context for agents

    /// One-line description of what an agent is doing, for other agents.
    func describe(_ a: Agent) -> String {
        var parts: [String] = []
        let st = a.displayStatus(staleMinutes: AppSettings.staleMinutes)
        parts.append(st.label)
        if !a.branch.isEmpty { parts.append("ветка \(a.branch)") }
        if let t = db.query("SELECT * FROM tasks WHERE assignee=? AND status IN ('in_progress','review') ORDER BY updated_at DESC LIMIT 1",
                            [a.id]).first.map(TaskItem.init) {
            parts.append("задача #\(t.id) «\(t.title.trunc(80))»")
        }
        if !a.focus.isEmpty { parts.append("фокус: \(a.focus.oneLine.trunc(160))") }
        else if !a.lastPrompt.isEmpty { parts.append("запрос: «\(a.lastPrompt.oneLine.trunc(140))»") }
        let files = recentFiles(agent: a.id, limit: 6)
        if !files.isEmpty { parts.append("правит: " + files.joined(separator: ", ")) }
        return "- \(a.name) [\(a.id), \(a.toolLabel)]: " + parts.joined(separator: "; ")
    }

    func othersDigest(project: String, me: String?) -> String {
        activeAgents(project: project).filter { $0.id != me }.map(describe).joined(separator: "\n")
    }

    func boardText(project p: Project, me: Agent?, includeRules: Bool) -> String {
        var out: [String] = []
        if let me {
            out.append("[AgentBoard] Проект «\(p.name)». Ты — агент «\(me.name)», твой agent_id: \(me.id).")
        } else {
            out.append("[AgentBoard] Проект «\(p.name)».")
        }
        let others = othersDigest(project: p.id, me: me?.id)
        out.append(others.isEmpty ? "Других активных агентов сейчас нет." : "Сейчас в проекте работают:\n" + others)
        let open = tasks(project: p.id).prefix(25)
        if open.isEmpty {
            out.append("Открытых задач на доске нет.")
        } else {
            out.append("Открытые задачи:")
            for t in open {
                let who = t.assignee.flatMap { agent(id: $0)?.name } ?? "свободна"
                let client = t.client.isEmpty ? "" : ", клиент: \(t.client)"
                out.append("- #\(t.id) [\(t.status.label), \(who)\(client)] \(t.title.trunc(120))")
            }
        }
        let notes = db.query("SELECT * FROM events WHERE project_id=? AND kind IN ('note','commit') AND created_at > ? ORDER BY created_at DESC, id DESC LIMIT 6",
                             [p.id, now() - 6 * 3600]).map(EventItem.init)
        if !notes.isEmpty {
            out.append("Недавно:")
            for e in notes {
                let who = e.agentId.flatMap { agent(id: $0)?.name } ?? "человек"
                out.append("- \(Fmt.time(e.createdAt)) \(who): \(e.kind == "commit" ? "коммит " : "")\(e.title.oneLine.trunc(160))")
            }
        }
        if includeRules {
            out.append("""
            Правила работы в команде (инструменты MCP-сервера agentboard):
            1) Перед началом работы возьми задачу: claim_task(task_id) или create_task(title, client, claim=true).
            2) Объяви, над чем работаешь: set_focus(focus, files) — так другие агенты не тронут твои файлы.
            3) Не правь файлы, которые сейчас правит другой агент; если нужно — напиши post_note и согласуй.
            4) Закончил — update_task(task_id, status="review" или "done", note="что сделано").
            5) Если работа для клиента — указывай client. Человек видит всё это на панели AgentBoard.
            6) Если человек просит посмотреть, что делает другой агент / соседний терминал / «Вега» и т.п. —
               вызови agent_activity(agent) (имя или agent_id; без аргумента — обзор всех). Это реальные данные с панели.
            7) Чтобы что-то сообщить другому агенту — send_message(to, text); to="all" — всем. Сообщения тебе
               приходят автоматически в контекст с пометкой [AgentBoard].
            """)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Claude Code hooks

    private func hookOutput(_ event: String, context: String? = nil, decision: String? = nil, reason: String? = nil) -> Data {
        var h: JSON = ["hookEventName": event]
        if let context { h["additionalContext"] = context }
        if let decision { h["permissionDecision"] = decision }
        if let reason { h["permissionDecisionReason"] = reason }
        return jsonData(["hookSpecificOutput": h])
    }

    static func isGitCommit(_ cmd: String) -> Bool {
        cmd.range(of: #"(^|[;&|(\s])git(\s+-[cC]\s+\S+|\s+--[a-z-]+(=\S+)?)*\s+commit(\s|$)"#, options: .regularExpression) != nil
    }

    static func isGitPush(_ cmd: String) -> Bool {
        cmd.range(of: #"(^|[;&|(\s])git(\s+-[cC]\s+\S+|\s+--[a-z-]+(=\S+)?)*\s+push(\s|$)"#, options: .regularExpression) != nil
    }

    func handleClaudeHook(_ j: JSON, reply: @escaping (Data?) -> Void) {
        guard let event = j.str("hook_event_name"), let sid = j.str("session_id") else { reply(nil); return }
        let cwd = j.s("cwd")
        // Started inside a project folder, or already known, or (started elsewhere, e.g. ~/Desktop)
        // its tool call works on files of a project.
        var found = projectFor(cwd: cwd)
        if found == nil, let pid = db.query("SELECT project_id FROM agents WHERE tool='claude' AND session_id=?", [sid]).first?.s("project_id") {
            found = project(id: pid)
        }
        if found == nil, let input = j["tool_input"] as? JSON {
            let text = jsonString(input)
            found = allProjects().filter { $0.isMentioned(in: text) }.max { $0.path.count < $1.path.count }
        }
        guard let project = found else { reply(nil); return }
        let agent = touchAgent(tool: "claude", sessionId: sid, project: project, cwd: cwd,
                               transcript: j.str("transcript_path"), revive: event != "SessionEnd")
        if let tty = j.str("_tty"), tty != agent.tty { setAgent(agent.id, ["tty": tty]) }
        defer { changed() }

        switch event {
        case "SessionStart":
            let source = j.str("source") ?? "startup"
            let branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd, timeout: 5)
            setAgent(agent.id, ["status": "idle", "branch": branch.ok ? branch.line : agent.branch,
                                "last_action": "сессия: \(source)"])
            if source == "startup" || source == "resume" {
                addEvent(project: project.id, agent: agent.id, kind: "session_start",
                         title: "\(agent.name) подключился (\(agent.toolLabel))", detail: cwd)
            }
            lastInjected[agent.id] = othersDigest(project: project.id, me: agent.id)
            reply(hookOutput("SessionStart", context: boardText(project: project, me: agent, includeRules: true)))

        case "UserPromptSubmit":
            let prompt = j.s("prompt")
            setAgent(agent.id, ["status": "working", "last_prompt": prompt.trunc(2000), "last_action": "получил запрос"])
            if !prompt.hasPrefix("/") || prompt.count > 30 {
                addEvent(project: project.id, agent: agent.id, kind: "prompt",
                         title: "\(agent.name): \(prompt.oneLine.trunc(160))", detail: prompt.trunc(4000))
            }
            var ctx: [String] = []
            if AppSettings.injectContext {
                let digest = othersDigest(project: project.id, me: agent.id)
                if !digest.isEmpty && digest != lastInjected[agent.id] {
                    lastInjected[agent.id] = digest
                    ctx.append("[AgentBoard] Обновление: в проекте сейчас также работают:\n\(digest)\nТвой agent_id: \(agent.id). Подробности о любом агенте — agent_activity(agent).")
                }
            }
            if let inbox = takeInbox(agent: agent.id) { ctx.append(inbox) }
            reply(ctx.isEmpty ? nil : hookOutput("UserPromptSubmit", context: ctx.joined(separator: "\n\n")))

        case "PostToolUse":
            // Delivery point for messages while the agent is busy.
            if let inbox = takeInbox(agent: agent.id) {
                reply(hookOutput("PostToolUse", context: inbox))
            } else {
                reply(nil)
            }

        case "PreToolUse":
            let tool = j.s("tool_name")
            let input = j["tool_input"] as? JSON ?? [:]
            if tool == "Bash" {
                let cmd = input.s("command")
                setAgent(agent.id, ["status": "working", "last_action": "$ " + cmd.oneLine.trunc(200)])
                addAction(agent: agent, title: "$ " + cmd.oneLine.trunc(240), detail: (input.str("description") ?? "") + "\n" + cmd.trunc(2000))
                if Self.isGitCommit(cmd) {
                    startCommitFlow(agent: agent, project: project, command: cmd, cwd: cwd, reply: reply)
                    return
                }
                if Self.isGitPush(cmd) {
                    addEvent(project: project.id, agent: agent.id, kind: "push", title: "\(agent.name): git push", detail: cmd)
                }
                reply(nil)
            } else if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool) {
                let full = input.str("file_path") ?? input.s("notebook_path")
                let rel = relativePath(full, agent: agent, project: project)
                let verb = tool == "Write" ? "пишет" : "правит"
                setAgent(agent.id, ["status": "working", "last_action": "\(verb) \(rel)"])
                touchFile(agent: agent, path: rel)
                addAction(agent: agent, title: "\(verb) \(rel)", detail: "")
                let others = AppSettings.conflictWarnings ? othersTouching(path: rel, project: project.id, except: agent.id) : []
                if !others.isEmpty {
                    let names = others.map(\.name).joined(separator: ", ")
                    let key = agent.id + "|" + rel
                    if now() - (conflictSeen[key] ?? 0) > 1800 {
                        conflictSeen[key] = now()
                        addEvent(project: project.id, agent: agent.id, kind: "conflict",
                                 title: "\(agent.name) правит \(rel), который недавно менял(и) \(names)", ref: rel)
                        if AppSettings.notifyConflicts {
                            notify?("Возможный конфликт · \(project.name)", "\(agent.name) правит \(rel) — его недавно менял(и) \(names)")
                        }
                    }
                    reply(hookOutput("PreToolUse",
                                     context: "[AgentBoard] Внимание: файл \(rel) недавно правил(и) \(names). Не затирай их изменения; при необходимости согласуй через post_note или выбери другую задачу."))
                } else {
                    reply(nil)
                }
            } else if tool.hasPrefix("mcp__agentboard__") {
                let short = String(tool.dropFirst("mcp__agentboard__".count))
                mcpCalls.removeAll { now() - $0.at > 60 }
                mcpCalls.append((agent.id, short, jsonString(input), now()))
                addAction(agent: agent, title: "agentboard: \(short)", detail: jsonString(input).trunc(1000))
                reply(nil)
            } else {
                let (verb, detail) = Self.describeTool(tool, input, agent: agent, project: project, core: self)
                setAgent(agent.id, ["status": "working", "last_action": verb.trunc(200)])
                addAction(agent: agent, title: verb.trunc(240), detail: detail)
                reply(nil)
            }

        case "Notification":
            let msg = j.str("message") ?? "Агент ждёт вашего ответа"
            setAgent(agent.id, ["status": "waiting", "last_action": msg.trunc(200)])
            addEvent(project: project.id, agent: agent.id, kind: "waiting", title: "\(agent.name): \(msg.trunc(200))")
            if AppSettings.notifyWaiting { notify?("\(agent.name) · \(project.name)", msg) }
            reply(nil)

        case "Stop":
            let text = Self.lastAssistantText(transcript: j.str("transcript_path") ?? agent.transcriptPath)
            setAgent(agent.id, ["status": "idle", "last_action": text.isEmpty ? "ход завершён" : "ответил: " + text.oneLine.trunc(160)])
            addEvent(project: project.id, agent: agent.id, kind: "turn_done",
                     title: "\(agent.name) завершил ход", detail: text.trunc(3000))
            // A message arrived while it was working: don't let it stop until it has read it.
            if let inbox = takeInbox(agent: agent.id) {
                setAgent(agent.id, ["status": "working", "last_action": "читает новые сообщения"])
                reply(jsonData(["decision": "block", "reason": inbox]))
            } else {
                reply(nil)
            }

        case "SessionEnd":
            setAgent(agent.id, ["status": "ended", "ended_at": now(), "last_action": "сессия закрыта"])
            addEvent(project: project.id, agent: agent.id, kind: "session_end", title: "\(agent.name) отключился")
            lastInjected[agent.id] = nil
            reply(nil)

        default:
            reply(nil)
        }
    }

    /// Human-readable line for any Claude Code tool call.
    static func describeTool(_ tool: String, _ input: JSON, agent: Agent, project: Project, core: Core) -> (String, String) {
        func rel(_ p: String) -> String { core.relativePath(p, agent: agent, project: project) }
        switch tool {
        case "Read": return ("читает \(rel(input.s("file_path")))", "")
        case "Grep": return ("ищет «\(input.s("pattern").trunc(80))»\(input.str("path").map { " в \(rel($0))" } ?? "")", "")
        case "Glob": return ("ищет файлы \(input.s("pattern"))", "")
        case "LS": return ("смотрит папку \(rel(input.s("path")))", "")
        case "WebFetch": return ("открывает \(input.s("url").trunc(160))", input.s("prompt").trunc(500))
        case "WebSearch": return ("ищет в сети: \(input.s("query").trunc(160))", "")
        case "Task", "Agent": return ("запускает субагента: \(input.s("description").trunc(160))", input.s("prompt").trunc(2000))
        case "TodoWrite":
            let todos = (input["todos"] as? [JSON]) ?? []
            let current = todos.first { $0.s("status") == "in_progress" }?.s("content") ?? todos.first?.s("content") ?? ""
            return ("план: \(current.trunc(180))", todos.map { "[\($0.s("status"))] \($0.s("content"))" }.joined(separator: "\n"))
        default:
            let args = jsonString(input)
            return ("\(tool.replacingOccurrences(of: "mcp__", with: "")) \(args.oneLine.trunc(140))", args.trunc(1500))
        }
    }

    /// Reads the tail of a Claude Code transcript and returns the last assistant text.
    static func lastAssistantText(transcript: String) -> String {
        guard !transcript.isEmpty, let fh = FileHandle(forReadingAtPath: transcript) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 400_000
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        let data = (try? fh.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            guard let obj = parseJSON(Data(line.utf8)) as? JSON, obj.s("type") == "assistant",
                  let msg = obj["message"] as? JSON, let content = msg["content"] as? [JSON] else { continue }
            let text = content.filter { $0.s("type") == "text" }.map { $0.s("text") }.joined(separator: "\n").trimmed
            if !text.isEmpty { return text }
        }
        return ""
    }

    // MARK: - Commits

    private func startCommitFlow(agent: Agent, project: Project, command: String, cwd: String, reply: @escaping (Data?) -> Void) {
        let status = Shell.git(["status", "--short", "--branch"], cwd: cwd, timeout: 8).out.trunc(4000)
        addEvent(project: project.id, agent: agent.id, kind: "commit_request",
                 title: "\(agent.name) готовит коммит", detail: command + "\n\n" + status)
        switch AppSettings.commitMode {
        case .off:
            reply(nil)
        case .notify:
            notify?("\(agent.name) коммитит · \(project.name)", command.oneLine.trunc(200))
            reply(nil)
        case .approve:
            let id = UUID().uuidString
            let timeout = AppSettings.approvalTimeout
            let pc = PendingCommit(id: id, agentId: agent.id, agentName: agent.name, projectId: project.id,
                                   projectName: project.name, command: command, gitStatus: status,
                                   createdAt: now(), deadline: now() + timeout)
            let work = DispatchWorkItem { [weak self] in self?.resolveCommit(id: id, allow: nil, comment: "") }
            pending[id] = PendingEntry(commit: pc, reply: reply, timer: work)
            setAgent(agent.id, ["status": "waiting", "last_action": "ждёт одобрения коммита"])
            q.asyncAfter(deadline: .now() + timeout, execute: work)
            notify?("Одобрить коммит? · \(project.name)", "\(agent.name): \(command.oneLine.trunc(180))")
        }
    }

    /// allow == nil means timeout: hand the decision back to Claude Code's own prompt.
    func resolveCommit(id: String, allow: Bool?, comment: String) {
        guard let e = pending.removeValue(forKey: id) else { return }
        e.timer.cancel()
        let c = e.commit
        switch allow {
        case .some(true):
            e.reply(hookOutput("PreToolUse", decision: "allow", reason: "Коммит одобрен человеком в AgentBoard"))
            addEvent(project: c.projectId, agent: c.agentId, kind: "commit_approved", title: "Коммит \(c.agentName) одобрен", detail: comment)
        case .some(false):
            let reason = "Человек отклонил коммит в AgentBoard." + (comment.isEmpty ? "" : " Комментарий: \(comment)")
            e.reply(hookOutput("PreToolUse", decision: "deny", reason: reason))
            addEvent(project: c.projectId, agent: c.agentId, kind: "commit_denied", title: "Коммит \(c.agentName) отклонён", detail: comment)
        case .none:
            e.reply(hookOutput("PreToolUse", decision: "ask", reason: "AgentBoard не дождался решения — подтвердите в терминале"))
            addEvent(project: c.projectId, agent: c.agentId, kind: "commit_timeout", title: "Коммит \(c.agentName): решение не принято вовремя")
        }
        setAgent(c.agentId, ["status": "working"])
        changed()
    }

    func handleGitCommit(_ j: JSON) {
        let cwd = j.s("cwd"), hash = j.s("hash")
        guard !hash.isEmpty, let project = projectFor(cwd: cwd) else { return }
        if !db.query("SELECT id FROM events WHERE kind='commit' AND ref=?", [hash]).isEmpty { return }
        let info = Shell.git(["show", "-s", "--format=%h%n%an%n%s%n%b", hash], cwd: cwd).out.components(separatedBy: "\n")
        guard info.count >= 3 else { return }
        let short = info[0], author = info[1], subject = info[2]
        let body = info.dropFirst(3).joined(separator: "\n").trimmed
        let files = Shell.git(["diff-tree", "--no-commit-id", "--name-status", "-r", "--root", hash], cwd: cwd).out
        let stat = Shell.git(["show", "--shortstat", "--format=", hash], cwd: cwd).line
        let branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd).line

        // Attribute to the agent working in this checkout that most recently ran git commit.
        let candidates = agents(project: project.id)
            .filter { $0.status != "ended" || now() - ($0.endedAt ?? 0) < 120 }
            .filter { $0.root == cwd || $0.cwd == cwd || $0.cwd.hasPrefix(cwd + "/") }
            .filter { now() - $0.lastSeen < 900 }
        let author_agent = candidates.first { $0.lastAction.contains("git") && $0.lastAction.contains("commit") }
            ?? candidates.first { $0.status == "waiting" || $0.status == "working" }
            ?? candidates.first
        var detail = "Ветка: \(branch)\nАвтор: \(author)\n\(stat)\n\n\(files.trunc(3000))"
        if !body.isEmpty { detail = body.trunc(1500) + "\n\n" + detail }
        addEvent(project: project.id, agent: author_agent?.id, kind: "commit", title: "\(short) \(subject)", detail: detail, ref: hash)
        if let a = author_agent {
            setAgent(a.id, ["last_action": "закоммитил \(short): \(subject.trunc(120))", "branch": branch])
        }
        if AppSettings.notifyCommits {
            notify?("\(author_agent?.name ?? author) · коммит в \(project.name)", "\(short) \(subject)\n\(stat)")
        }
        changed()
    }

    // MARK: - Codex notify

    func handleCodexNotify(_ j: JSON) {
        guard j.s("type") == "agent-turn-complete" else { return }
        let thread = j.str("thread-id") ?? j.str("thread_id") ?? j.str("session-id") ?? j.str("turn-id") ?? UUID().uuidString
        var cwd = j.str("cwd") ?? ""
        var project = projectFor(cwd: cwd)
        if project == nil {
            let all = allProjects()
            if all.count == 1 { project = all[0]; cwd = all[0].path }
        }
        guard let project else { return }
        let agent = touchAgent(tool: "codex", sessionId: thread, project: project, cwd: cwd, transcript: nil, revive: true)
        if CodexWatcher.shared.isWatched(thread) { changed(); return }
        let inputs = (j["input-messages"] as? [String]) ?? (j["input_messages"] as? [String]) ?? []
        let answer = j.str("last-assistant-message") ?? j.str("last_assistant_message") ?? ""
        var f: [String: Any] = ["status": "idle", "last_action": answer.isEmpty ? "ход завершён" : "ответил: " + answer.oneLine.trunc(160)]
        if let p = inputs.last { f["last_prompt"] = p.trunc(2000) }
        setAgent(agent.id, f)
        if let p = inputs.last {
            addEvent(project: project.id, agent: agent.id, kind: "prompt", title: "\(agent.name): \(p.oneLine.trunc(160))", detail: p.trunc(4000))
        }
        addEvent(project: project.id, agent: agent.id, kind: "turn_done", title: "\(agent.name) завершил ход", detail: answer.trunc(3000))
        changed()
    }

    // MARK: - Routing

    func route(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        // Browsers always send Origin on cross-site POSTs; agents and curl don't. Blocks drive-by requests from web pages.
        if let origin = req.headers["origin"], !origin.hasPrefix("http://127.0.0.1"), !origin.hasPrefix("http://localhost") {
            reply(.json(["error": "forbidden origin"], status: 403)); return
        }
        let body = parseJSON(req.body)
        switch (req.method, req.path) {
        case ("GET", "/health"):
            reply(.json(["ok": true, "app": "AgentBoard", "version": AppInfo.version]))
        case ("POST", "/hook/claude"):
            guard let j = body as? JSON else { reply(.empty()); return }
            var jj = j
            if let tty = req.query["tty"], tty.hasPrefix("ttys") { jj["_tty"] = "/dev/" + tty }
            handleClaudeHook(jj) { data in
                if let data { reply(HTTPResponse(status: 200, body: data)) } else { reply(.empty()) }
            }
        case ("POST", "/hook/codex"):
            if let j = body as? JSON { handleCodexNotify(j) }
            reply(.empty())
        case ("POST", "/hook/git"):
            if let j = body as? JSON { handleGitCommit(j) }
            reply(.empty())
        case ("POST", "/mcp"):
            if let out = handleMCP(req.body) {
                reply(HTTPResponse(status: 200, body: out))
            } else {
                reply(.empty(202))
            }
        case ("GET", "/mcp"):
            reply(.empty(405))
        case ("DELETE", "/mcp"):
            reply(.empty(200))
        case ("GET", "/api/board"):
            let projects = allProjects()
            let text = projects.map { boardText(project: $0, me: nil, includeRules: false) }.joined(separator: "\n\n")
            reply(HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8)))
        default:
            reply(.json(["error": "not found"], status: 404))
        }
    }

    // MARK: - MCP session mapping

    /// Finds which Claude Code session made this MCP call, using the PreToolUse hook that fired just before it.
    func agentForMCPCall(tool: String, args: JSON) -> Agent? {
        let canon = jsonString(args)
        if let i = mcpCalls.firstIndex(where: { $0.tool == tool && $0.args == canon && now() - $0.at < 60 }) {
            let a = mcpCalls.remove(at: i)
            return agent(id: a.agentId)
        }
        return nil
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
