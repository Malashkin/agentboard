import CoreGraphics
import Foundation

/// Your agents on your phone, through a Telegram bot you own: requests arrive with buttons (Allow / Deny /
/// the question's options / Approve plan), "waiting for you" arrives as a message you answer by replying.
/// The Mac polls Telegram (long polling), so nothing has to reach the Mac from outside — no server, no port.
/// Only the one chat paired with a code shown in the app is listened to.
enum TelegramLink {
    struct Button: Equatable { var label: String; var data: String }
    struct Outgoing: Equatable { var text: String; var buttons: [[Button]] = [] }

    /// What a message on the phone points at, so a reply or a button knows where to go.
    enum Target: Equatable { case request(String), agent(String) }

    enum Action: Equatable {
        case decide(id: String, allow: Bool, comment: String, answer: String?, always: Bool)
        case reply(agent: String, text: String)
        case pair(chat: Int64, code: String)
        case status
        case ignore
    }

    // MARK: Out

    static func message(for p: PendingCommit) -> Outgoing {
        var o = Outgoing(text: "")
        switch p.kind {
        case "question":
            let q = p.questions.first
            o.text = "❓ \(p.agentName) asks · \(p.projectName)\n\n\(q?.question ?? p.command)"
            if let q, p.questions.count == 1, !q.multiSelect {
                o.buttons = q.options.prefix(6).enumerated().map { [Button(label: $1.label.trunc(40), data: "o:\(p.id):\($0)")] }
            }
            o.text += "\n\nTap an option, or reply to this message with your own answer."
        case "plan":
            o.text = "📋 \(p.agentName) proposes a plan · \(p.projectName)\n\n\(p.gitStatus.trunc(3000))\n\nReply to this message to send it back with changes."
            o.buttons = [[Button(label: "Approve plan", data: "a:\(p.id)")]]
        case "permission":
            o.text = "🔐 \(p.agentName) asks permission · \(p.projectName)\n\n\(p.command.trunc(1500))\n\nReply to deny with a comment."
            var row = [Button(label: "Allow", data: "a:\(p.id)")]
            if p.canAlwaysAllow { row.append(Button(label: "Allow for session", data: "w:\(p.id)")) }
            row.append(Button(label: "Deny", data: "d:\(p.id)"))
            o.buttons = [row]
        default:
            o.text = "📦 Approve commit? · \(p.projectName)\n\n\(p.agentName): \(p.command.trunc(1500))\n\nReply to deny with a comment."
            o.buttons = [[Button(label: "Allow", data: "a:\(p.id)"), Button(label: "Deny", data: "d:\(p.id)")]]
        }
        return o
    }

    static func waiting(agent: String, title: String, body: String) -> Outgoing {
        Outgoing(text: "⏳ \(title)\n\n\(body.trunc(1500))\n\nReply to this message to answer \(agent).")
    }

    static func keyboard(_ rows: [[Button]]) -> JSON {
        ["inline_keyboard": rows.map { $0.map { ["text": $0.label, "callback_data": $0.data] } }]
    }

    // MARK: In

    /// One Telegram update → what to do. `chat` is the paired chat (nil while pairing with `code`);
    /// `sent` maps our message ids to what they were about; `pending` resolves question options.
    static func parse(_ u: JSON, chat: Int64?, code: String?, sent: [Int64: Target], pending: [PendingCommit]) -> Action {
        if let cb = u["callback_query"] as? JSON {
            let from = ((cb["message"] as? JSON)?["chat"] as? JSON)?["id"] as? NSNumber
            guard let chat, from?.int64Value == chat else { return .ignore }
            let parts = cb.s("data").split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return .ignore }
            let id = parts[1]
            switch parts[0] {
            case "a": return .decide(id: id, allow: true, comment: "", answer: nil, always: false)
            case "w": return .decide(id: id, allow: true, comment: "", answer: nil, always: true)
            case "d": return .decide(id: id, allow: false, comment: "", answer: nil, always: false)
            case "o":
                guard parts.count == 3, let i = Int(parts[2]), let p = pending.first(where: { $0.id == id }),
                      let q = p.questions.first, i < q.options.count else { return .ignore }
                return .decide(id: id, allow: true, comment: "", answer: q.options[i].label, always: false)
            default: return .ignore
            }
        }
        guard let m = u["message"] as? JSON, let c = (m["chat"] as? JSON)?["id"] as? NSNumber else { return .ignore }
        let text = m.s("text").trimmed
        if let code, text == "/start \(code)" || text == code { return .pair(chat: c.int64Value, code: code) }
        guard let chat, c.int64Value == chat, !text.isEmpty else { return .ignore }
        if text == "/status" || text == "/start" { return .status }
        guard let rid = ((m["reply_to_message"] as? JSON)?["message_id"] as? NSNumber)?.int64Value, let t = sent[rid] else { return .status }
        switch t {
        case .agent(let a): return .reply(agent: a, text: text)
        case .request(let id):
            let p = pending.first { $0.id == id }
            if p?.kind == "question" { return .decide(id: id, allow: true, comment: "", answer: text, always: false) }
            return .decide(id: id, allow: false, comment: text, answer: nil, always: false)
        }
    }

    /// The Mac has had no keyboard or mouse input for `minutes` (or its screen is locked).
    static func awayFromMac(minutes: Double = 5) -> Bool {
        let kinds: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        let idle = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        return idle >= minutes * 60
    }
}

/// The running link: settings, polling, sending.
final class Telegram {
    static let shared = Telegram()
    private let queue = DispatchQueue(label: "agentboard.telegram")
    private var polling = false
    private var offset: Int64 = 0
    private var sent: [Int64: TelegramLink.Target] = [:]
    private var requestMessages: [String: Int64] = [:]
    /// Shown in Settings while pairing; the chat that sends it becomes the paired one.
    private(set) var pairingCode: String?
    var onChange: (() -> Void)?

    struct Config: Codable { var token = ""; var chat: Int64?; var onlyAway = true; var username = "" }
    private(set) var config = Config()

    var path: String { Integrations.baseDir + "/telegram.json" }
    var isPaired: Bool { !config.token.isEmpty && config.chat != nil }

    func load() {
        if let d = FileManager.default.contents(atPath: path), let c = try? JSONDecoder().decode(Config.self, from: d) { config = c }
        if isPaired { startPolling() }
    }

    private func save() {
        // Holds the bot token: owner-only, like ~/.agentboard/token.
        if let d = try? JSONEncoder().encode(config) {
            FileManager.default.createFile(atPath: path, contents: d, attributes: [.posixPermissions: 0o600])
        }
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Checks the token with Telegram, then waits for the pairing code in a chat with the bot.
    func connect(token: String, done: @escaping (String?) -> Void) {
        queue.async {
            let me = self.call("getMe", [:], token: token.trimmed)
            guard let user = me?["result"] as? JSON else {
                DispatchQueue.main.async { done("Telegram didn't accept that token. Copy it again from @BotFather.") }
                return
            }
            self.config = Config(token: token.trimmed, chat: nil, onlyAway: self.config.onlyAway, username: user.s("username"))
            self.pairingCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
            self.save()
            self.startPolling()
            DispatchQueue.main.async { done(nil) }
        }
    }

    func disconnect() {
        queue.async {
            self.config = Config(onlyAway: self.config.onlyAway)
            self.pairingCode = nil
            self.sent = [:]
            self.requestMessages = [:]
            try? FileManager.default.removeItem(atPath: self.path)
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    func setOnlyAway(_ v: Bool) { queue.async { self.config.onlyAway = v; self.save() } }

    // MARK: Out

    private var shouldSend: Bool { isPaired && (!config.onlyAway || TelegramLink.awayFromMac()) }

    func request(_ p: PendingCommit) {
        queue.async {
            guard self.shouldSend else { return }
            if let id = self.send(TelegramLink.message(for: p)) {
                self.sent[id] = .request(p.id)
                self.requestMessages[p.id] = id
            }
        }
    }

    func waiting(_ a: Agent, title: String, body: String) {
        queue.async {
            guard self.shouldSend else { return }
            if let id = self.send(TelegramLink.waiting(agent: a.name, title: title, body: body)) { self.sent[id] = .agent(a.id) }
        }
    }

    func note(_ text: String) {
        queue.async { if self.shouldSend { _ = self.send(.init(text: text)) } }
    }

    func sendTest(done: @escaping (String) -> Void) {
        queue.async {
            let ok = self.isPaired && self.send(.init(text: "✅ AgentBoard is connected. Requests and agents waiting for you will arrive here.")) != nil
            DispatchQueue.main.async { done(ok ? "Sent — check Telegram." : "Couldn't send. Is the bot paired?") }
        }
    }

    /// Answered on the Mac, in the terminal or by timeout: the phone's buttons go away.
    func resolved(request id: String) {
        queue.async {
            guard let mid = self.requestMessages.removeValue(forKey: id), let chat = self.config.chat else { return }
            _ = self.call("editMessageReplyMarkup", ["chat_id": chat, "message_id": mid, "reply_markup": ["inline_keyboard": [] as [Any]]])
        }
    }

    @discardableResult
    private func send(_ o: TelegramLink.Outgoing) -> Int64? {
        guard let chat = config.chat else { return nil }
        var body: JSON = ["chat_id": chat, "text": o.text.trunc(4000), "disable_web_page_preview": true]
        if !o.buttons.isEmpty { body["reply_markup"] = TelegramLink.keyboard(o.buttons) }
        return ((call("sendMessage", body)?["result"] as? JSON)?["message_id"] as? NSNumber)?.int64Value
    }

    // MARK: In

    private func startPolling() {
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async { self.pollLoop() }
    }

    private func pollLoop() {
        while true {
            let token = queue.sync { config.token }
            guard !token.isEmpty else { queue.sync { polling = false }; return }
            let res = call("getUpdates", ["offset": offset, "timeout": 25, "allowed_updates": ["message", "callback_query"]],
                           token: token, timeout: 35)
            guard let updates = res?["result"] as? [JSON] else { Thread.sleep(forTimeInterval: 5); continue }
            for u in updates {
                if let id = (u["update_id"] as? NSNumber)?.int64Value { offset = max(offset, id + 1) }
                handle(u)
            }
        }
    }

    private func handle(_ u: JSON) {
        let (chat, code, sent) = queue.sync { (config.chat, pairingCode, self.sent) }
        let pending = DispatchQueue.main.sync { Store.shared.pending }
        let action = TelegramLink.parse(u, chat: chat, code: code, sent: sent, pending: pending)
        if let cb = u["callback_query"] as? JSON { _ = call("answerCallbackQuery", ["callback_query_id": cb.s("id")]) }
        switch action {
        case .pair(let c, _):
            queue.async {
                self.config.chat = c
                self.pairingCode = nil
                self.save()
                _ = self.send(.init(text: "✅ Paired with AgentBoard. Requests and agents waiting for you will arrive here"
                                    + (self.config.onlyAway ? " while you're away from the Mac (5 min without input)." : ".")))
            }
        case .decide(let id, let allow, let comment, let answer, let always):
            DispatchQueue.main.async {
                let store = Store.shared
                guard let p = store.pending.first(where: { $0.id == id }) else {
                    self.note("That request was already answered.")
                    return
                }
                let answers = answer.map { a in p.questions.first.map { [$0.question: a] } ?? [:] } ?? [:]
                store.decide(id, allow: allow, comment: comment, answers: answers, always: always)
                self.note(allow ? "✓ \(p.agentName): " + (answer.map { "answered “\($0)”" } ?? "allowed") : "✗ \(p.agentName): denied")
            }
        case .reply(let agent, let text):
            SessionDelivery.deliver(agentId: agent, text: text, mode: .auto) { r in self.note("→ " + r) }
        case .status:
            DispatchQueue.main.async {
                let store = Store.shared
                let q = store.attentionQueue
                var lines = ["AgentBoard: \(store.pending.count) request(s), \(q.count) agent(s) waiting or idle."]
                lines += q.prefix(8).map { "• \($0.name) (\(store.project($0.projectId)?.name ?? "")) — \(store.status($0).label)" }
                self.queue.async { _ = self.send(.init(text: lines.joined(separator: "\n"))) }
            }
        case .ignore:
            break
        }
    }

    // MARK: HTTP

    private func call(_ method: String, _ body: JSON, token: String? = nil, timeout: Double = 15) -> JSON? {
        let t = token ?? config.token
        guard !t.isEmpty, let url = URL(string: "https://api.telegram.org/bot\(t)/\(method)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData(body)
        let sem = DispatchSemaphore(value: 0)
        var out: JSON?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            out = data.flatMap { parseJSON($0) as? JSON }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return out?["ok"] as? Bool == true ? out : nil
    }
}
