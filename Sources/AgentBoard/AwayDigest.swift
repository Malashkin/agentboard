import AppKit
import Foundation

/// "While you were away": when you come back to AgentBoard after a while (app in the background,
/// screen asleep), a short digest of what the agents did meanwhile — written by a small model,
/// with a plain list as fallback.
struct AwayDigest: Equatable {
    var from: Double
    var to: Double
    var text: String
    var commits: Int
    var questions: Int
    var stuck: Int
    var finished: Int
    var writing: Bool
}

final class AwayWatcher {
    static let shared = AwayWatcher()
    private var awaySince: Double?
    /// When the human last left the Mac (kept after they come back), for "since I was away" in the replay.
    private(set) var lastAwayStart: Double?
    private let queue = DispatchQueue(label: "agentboard.away")

    func start() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.left() }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.left() }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.left() }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.back() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            if NSApp.isActive { self?.back() }
        }
        if !NSApp.isActive { awaySince = now() }
    }

    private func left() { if awaySince == nil { awaySince = now(); lastAwayStart = awaySince } }

    private func back() {
        guard let since = awaySince else { return }
        awaySince = nil
        guard AppSettings.awayDigest, now() - since >= AppSettings.awayMinutes * 60 else { return }
        build(from: since, to: now())
    }

    /// Also available on demand ("what happened in the last hour").
    func build(from: Double, to: Double) {
        let core = Core.shared
        queue.async {
            let (facts, digest) = core.q.sync { () -> (String, AwayDigest) in
                let rows = core.db.query("""
                    SELECT * FROM events WHERE created_at >= ? AND created_at < ?
                      AND kind IN ('commit','turn_done','permission','waiting','stuck','conflict','task_created','task_status','note','prompt','commit_request')
                    ORDER BY created_at
                    """, [from, to]).map(EventItem.init)
                var d = AwayDigest(from: from, to: to, text: "", commits: rows.filter { $0.kind == "commit" }.count,
                                   questions: core.pending.count,
                                   stuck: rows.filter { $0.kind == "stuck" }.count,
                                   finished: rows.filter { $0.kind == "turn_done" }.count, writing: true)
                let names = Dictionary(uniqueKeysWithValues: core.allProjects().map { ($0.id, $0.name) })
                let lines = rows.suffix(150).map { e -> String in
                    var l = "\(Fmt.time(e.createdAt)) [\(names[e.projectId] ?? "")] \(e.title.oneLine.trunc(200))"
                    if e.kind == "turn_done", !e.detail.isEmpty { l += " — " + e.detail.oneLine.trunc(300) }
                    return l
                }
                let open = core.pending.values.map { "- waiting for you: \($0.commit.agentName) — \($0.commit.command.oneLine.trunc(150))" }
                d.text = Self.fallback(rows, names)
                return ((lines + open).joined(separator: "\n"), d)
            }
            guard digest.commits + digest.finished + digest.stuck + digest.questions > 0 else { return }
            DispatchQueue.main.async { Store.shared.awayDigest = digest }
            guard !AppDelegate.isTesting, AppSettings.narrator, let claude = Shell.which("claude") else {
                DispatchQueue.main.async { Store.shared.awayDigest?.writing = false }
                return
            }
            let mins = Int((to - from) / 60)
            let prompt = """
            The human was away for \(mins) minutes while several AI coding agents worked. From the log below, tell them
            in 3–6 short bullet points what happened: what got done, what is waiting for their decision, who is stuck.
            Plain words, most important first, no headings, no invented facts. Bullets start with "• ".

            LOG:
            \(facts.trunc(20000))
            """
            let r = Shell.run(claude, Shell.modelArgs(model: AppSettings.narratorModel),
                              cwd: core.supportDir.path, input: prompt, timeout: 90)
            let text = r.out.trimmed
            DispatchQueue.main.async {
                guard Store.shared.awayDigest?.from == from else { return }
                if r.ok && !text.isEmpty { Store.shared.awayDigest?.text = text }
                Store.shared.awayDigest?.writing = false
            }
        }
    }

    static func fallback(_ rows: [EventItem], _ names: [String: String]) -> String {
        let important = rows.filter { ["commit", "stuck", "conflict", "task_status", "turn_done"].contains($0.kind) }.suffix(8)
        return important.map { "• \(Fmt.time($0.createdAt)) \(names[$0.projectId] ?? ""): \($0.title.oneLine.trunc(140))" }.joined(separator: "\n")
    }
}
