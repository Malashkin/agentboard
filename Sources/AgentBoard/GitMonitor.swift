import Foundation

/// Polls git for every project: worktrees, uncommitted changes, today's commits.
final class GitMonitor {
    static let shared = GitMonitor()
    private let queue = DispatchQueue(label: "agentboard.git")
    private var timer: DispatchSourceTimer?
    var onUpdate: (([String: GitSnapshot]) -> Void)?

    func start(interval: Double = 15) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func refreshNow() { queue.async { [weak self] in self?.refresh() } }

    private func refresh() {
        let projects = Core.shared.q.sync { Core.shared.allProjects() }
        var out: [String: GitSnapshot] = [:]
        for p in projects { out[p.id] = Self.snapshot(path: p.path) }
        DispatchQueue.main.async { self.onUpdate?(out) }
    }

    static func snapshot(path: String) -> GitSnapshot {
        var snap = GitSnapshot(updatedAt: now())
        let list = Shell.git(["worktree", "list", "--porcelain"], cwd: path)
        guard list.ok else {
            snap.error = list.err.trimmed.isEmpty ? "not a git repository" : list.err.trimmed
            return snap
        }
        var paths: [String] = []
        for line in list.out.split(separator: "\n") where line.hasPrefix("worktree ") {
            paths.append(String(line.dropFirst("worktree ".count)))
        }
        for wt in paths.prefix(20) {
            let st = Shell.git(["status", "--porcelain=v1", "-b"], cwd: wt, timeout: 10)
            guard st.ok else { continue }
            var lines = st.out.split(separator: "\n").map(String.init)
            var info = WorktreeInfo(path: wt, branch: "?", ahead: 0, behind: 0, changes: [])
            if let head = lines.first, head.hasPrefix("## ") {
                lines.removeFirst()
                let h = String(head.dropFirst(3))
                info.branch = h.components(separatedBy: "...").first?.components(separatedBy: " ").first ?? h
                if h.hasPrefix("No commits yet on ") { info.branch = String(h.dropFirst("No commits yet on ".count)) }
                if let r = h.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                    info.ahead = Int(h[r].split(separator: " ").last ?? "0") ?? 0
                }
                if let r = h.range(of: #"behind (\d+)"#, options: .regularExpression) {
                    info.behind = Int(h[r].split(separator: " ").last ?? "0") ?? 0
                }
            }
            info.changes = lines
            snap.worktrees.append(info)
        }
        let since = Fmt.gitDate.string(from: Calendar.current.startOfDay(for: Date()))
        let log = Shell.git(["log", "--all", "--no-merges", "--since=\(since)", "--format=%h%x09%ad%x09%an%x09%s",
                             "--date=format-local:%H:%M", "-n", "200"], cwd: path)
        for line in log.out.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if f.count == 4 { snap.todayCommits.append(CommitLine(hash: f[0], time: f[1], author: f[2], subject: f[3])) }
        }
        return snap
    }
}
