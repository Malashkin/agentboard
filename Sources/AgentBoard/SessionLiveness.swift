import Darwin
import Foundation

/// Knows which Claude Code sessions are really open, from the files Claude Code keeps in
/// ~/.claude/sessions/<pid>.json (pid, sessionId, cwd, status busy/idle). A pid is trusted only when
/// the process with that pid started at the recorded time, so a reused pid doesn't count.
/// - an open session stays "active" however long it sits idle;
/// - a session whose terminal was closed without SessionEnd is marked finished;
/// - a missed Stop (busy → idle) brings the agent back to "free".
final class SessionLiveness {
    static let shared = SessionLiveness()
    private let queue = DispatchQueue(label: "agentboard.liveness")
    private var timer: DispatchSourceTimer?

    struct Live { var pid: Int32; var sessionId: String; var cwd: String; var status: String; var updatedAt: Double }

    var dir: String {
        (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.claude") + "/sessions"
    }

    func start(interval: Double = 5) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// nil when this Claude Code version doesn't keep session files (then nothing is concluded).
    func liveSessions() -> [String: Live]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let files = names.filter { $0.hasSuffix(".json") }
        guard !files.isEmpty else { return [:] }
        var out: [String: Live] = [:]
        for n in files {
            guard let d = fm.contents(atPath: dir + "/" + n), let j = parseJSON(d) as? JSON,
                  let pid = (j["pid"] as? NSNumber)?.int32Value, let sid = j.str("sessionId") else { continue }
            guard Self.isAlive(pid: pid, procStart: j.s("procStart")) else { continue }
            out[sid] = Live(pid: pid, sessionId: sid, cwd: j.s("cwd"), status: j.s("status"),
                            updatedAt: ((j["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        }
        return out
    }

    static func isAlive(pid: Int32, procStart: String) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard !procStart.isEmpty, let started = startTime(pid: pid) else { return true }
        // procStart is ctime-style: "Sat Nov  7 20:23:52 2026".
        var t = time_t(started)
        var tmv = tm()
        localtime_r(&t, &tmv)
        var buf = [Int8](repeating: 0, count: 64)
        strftime(&buf, buf.count, "%a %b %e %H:%M:%S %Y", &tmv)
        let s = String(cString: buf)
        return s == procStart || abs(Self.parseCtime(procStart).map { $0 - started } ?? 0) <= 2
    }

    private static func parseCtime(_ s: String) -> Double? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: s.split(separator: " ").joined(separator: " "))?.timeIntervalSince1970
    }

    private static func startTime(pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec)
    }

    private func tick() {
        guard let live = liveSessions() else { return }
        let core = Core.shared
        core.q.async {
            var changed = false
            let t = now()
            for a in core.db.query("SELECT * FROM agents WHERE tool='claude' AND status != 'ended'").map(Agent.init) {
                if let l = live[a.sessionId] {
                    var f: [String: Any] = ["last_seen": t]
                    // A Stop we never heard about: Claude Code says idle for a while, we still say working.
                    if l.status == "idle", a.status == "working", t - l.updatedAt > 20, t - a.lastActionAt > 20 {
                        f["status"] = "idle"
                        f["stuck"] = ""
                        changed = true
                    }
                    core.db.update("agents", id: a.id, f)
                } else if a.tty.hasPrefix("/dev/tty"), t - a.lastSeen > 60, t - a.startedAt > 60 {
                    // Only interactive sessions (they have a terminal); background `claude -p` runs have no session file.
                    // No process behind this session any more: the terminal was closed.
                    core.setAgent(a.id, ["status": "ended", "ended_at": t, "last_action": "терминал закрыт"])
                    core.releaseReservations(agentId: a.id, patterns: nil)
                    core.dropPendingPermissions(agent: a.id, inputKey: nil)
                    core.addEvent(project: a.projectId, agent: a.id, kind: "session_end", title: "\(a.name) отключился (терминал закрыт)")
                    changed = true
                }
            }
            if changed { core.changed() }
        }
    }
}
