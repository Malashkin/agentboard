import AppKit
import UserNotifications

/// macOS notifications. Requests from agents (permission, question, plan, commit, "waiting for you")
/// carry action buttons and a reply field, so they can be answered without opening the window.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    private var categories: [String: UNNotificationCategory] = [:]
    private let lock = NSLock()

    func setup() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        register(UNNotificationCategory(identifier: "agent.waiting", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: "Reply…", options: [],
                                          textInputButtonTitle: "Send", textInputPlaceholder: "Message to the agent"),
        ], intentIdentifiers: []))
    }

    func post(_ title: String, _ body: String) {
        guard available else { NSLog("AgentBoard: \(title) — \(body)"); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The agent finished and waits for your next instruction: reply right from the notification.
    func postWaiting(agentId: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "agent.waiting"
        content.userInfo = ["agent": agentId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "waiting." + agentId, content: content, trigger: nil))
    }

    private func register(_ c: UNNotificationCategory) {
        lock.lock()
        categories[c.identifier] = c
        let all = Set(categories.values)
        lock.unlock()
        UNUserNotificationCenter.current().setNotificationCategories(all)
    }

    /// A pending request with its own buttons: Allow / Deny, the question's options, Approve plan…
    func postRequest(_ p: PendingCommit) {
        guard available else { NSLog("AgentBoard request: \(p.agentName) — \(p.command)"); return }
        var actions: [UNNotificationAction] = []
        let title: String
        var body = p.command
        switch p.kind {
        case "question":
            title = "\(p.agentName) asks · \(p.projectName)"
            if let q = p.questions.first {
                body = q.question
                if p.questions.count == 1 && !q.multiSelect {
                    for (i, o) in q.options.prefix(4).enumerated() {
                        actions.append(UNNotificationAction(identifier: "opt.\(i)", title: o.label, options: []))
                    }
                }
            }
            actions.append(UNTextInputNotificationAction(identifier: "answer", title: "Other answer…", options: [],
                                                         textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        case "plan":
            title = "\(p.agentName) proposes a plan · \(p.projectName)"
            body = p.gitStatus.oneLine.trunc(250)
            actions = [UNNotificationAction(identifier: "allow", title: "Approve plan", options: []),
                       UNTextInputNotificationAction(identifier: "deny.comment", title: "Request changes…", options: [],
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "What to change")]
        case "permission":
            title = "\(p.agentName) asks permission · \(p.projectName)"
            actions = [UNNotificationAction(identifier: "allow", title: "Allow", options: [])]
            if p.canAlwaysAllow { actions.append(UNNotificationAction(identifier: "always", title: "Allow for this session", options: [])) }
            actions.append(UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]))
            actions.append(UNTextInputNotificationAction(identifier: "deny.comment", title: "Deny with comment…", options: [],
                                                         textInputButtonTitle: "Send", textInputPlaceholder: "Why / what instead"))
        default:
            title = "Approve commit? · \(p.projectName)"
            body = "\(p.agentName): \(p.command)"
            actions = [UNNotificationAction(identifier: "allow", title: "Allow", options: []),
                       UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
                       UNTextInputNotificationAction(identifier: "deny.comment", title: "Deny with comment…", options: [],
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Comment for the agent")]
        }
        let cat = "req." + p.id
        register(UNNotificationCategory(identifier: cat, actions: actions, intentIdentifiers: []))
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.trunc(300)
        content.sound = .default
        content.categoryIdentifier = cat
        content.userInfo = ["request": p.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "req." + p.id, content: content, trigger: nil))
    }

    /// Answered elsewhere (app, terminal, timeout): take the notification away.
    func remove(request id: String) {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: ["req." + id])
        lock.lock()
        categories.removeValue(forKey: "req." + id)
        let all = Set(categories.values)
        lock.unlock()
        c.setNotificationCategories(all)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmed ?? ""
        DispatchQueue.main.async {
            let store = Store.shared
            if let agent = info["agent"] as? String, action == "reply", !text.isEmpty {
                SessionDelivery.deliver(agentId: agent, text: text, mode: .auto) { r in Notifier.shared.post("Sent", r) }
            } else if let id = info["request"] as? String, let p = store.pending.first(where: { $0.id == id }) {
                switch action {
                case "allow": store.decide(id, allow: true, comment: "")
                case "always": store.decide(id, allow: true, comment: "", always: true)
                case "deny": store.decide(id, allow: false, comment: "")
                case "deny.comment": store.decide(id, allow: false, comment: text)
                case "answer":
                    if let q = p.questions.first, !text.isEmpty { store.decide(id, allow: true, comment: "", answers: [q.question: text]) }
                    else { store.requestOpenMain() }
                default:
                    if action.hasPrefix("opt."), let i = Int(action.dropFirst(4)), let q = p.questions.first, i < q.options.count {
                        store.decide(id, allow: true, comment: "", answers: [q.question: q.options[i].label])
                    } else {
                        store.requestOpenMain()
                    }
                }
            } else {
                store.requestOpenMain()
            }
        }
        completionHandler()
    }
}
