import Foundation

/// Launching a task from the board: an isolated git worktree on its own branch, an agent started
/// in a terminal with the task as its prompt, then review of the branch's changes, merge or PR.
enum Workspaces {
    enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    static func slug(_ s: String) -> String {
        let map: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y",
            "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
            "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        ]
        var out = ""
        for ch in s.lowercased() {
            if let m = map[ch] { out += m }
            else if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
    }

    /// Creates (or reuses) the task's worktree. Returns path, branch, base branch.
    static func ensureWorktree(task t: TaskItem, project p: Project) throws -> (String, String, String) {
        if !t.worktree.isEmpty, FileManager.default.fileExists(atPath: t.worktree) { return (t.worktree, t.branch, t.baseBranch) }
        let base = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: p.path)
        guard base.ok else { throw Failure.message("\(p.path) is not a git repository") }
        let s = slug(t.title)
        let branch = "agent/\(t.id)" + (s.isEmpty ? "" : "-\(s)")
        let path = AppSettings.worktreeRoot + "/\(slug(p.name).isEmpty ? p.id : slug(p.name))-\(p.id)/\(t.id)" + (s.isEmpty ? "" : "-\(s)")
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let exists = Shell.git(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], cwd: p.path).ok
        let r = exists
            ? Shell.git(["worktree", "add", path, branch], cwd: p.path, timeout: 60)
            : Shell.git(["worktree", "add", "-b", branch, path, base.line], cwd: p.path, timeout: 60)
        guard r.ok else { throw Failure.message("git worktree add: \(r.err.trimmed.isEmpty ? r.out : r.err)".trunc(500)) }
        return (path, branch, base.line)
    }

    static func prompt(task t: TaskItem, branch: String, base: String, isolated: Bool) -> String {
        var s = "Task #\(t.id) from the AgentBoard board: \(t.title)"
        if !t.client.isEmpty { s += " (client: \(t.client))" }
        if !t.details.trimmed.isEmpty { s += "\n\n\(t.details.trimmed)" }
        s += "\n\n"
        if isolated {
            s += "You are working in a separate git worktree on branch \(branch) (branched off \(base)). Commit to this branch; "
                + "don't switch to or merge into \(base) — the human will do that after review. "
        }
        s += "The task is already assigned to you. When you're done — update_task(task_id: \(t.id), status: \"review\", note: \"what was done and how to verify it\")."
        return s
    }

    /// Opens a terminal running the agent. Returns a human-readable result.
    static func launch(task t: TaskItem, project p: Project, tool: String, isolated: Bool) throws -> String {
        var dir = p.path, branch = "", base = ""
        if isolated {
            (dir, branch, base) = try ensureWorktree(task: t, project: p)
        }
        let text = prompt(task: t, branch: branch, base: base, isolated: isolated)
        let promptDir = Integrations.baseDir + "/prompts"
        try FileManager.default.createDirectory(atPath: promptDir, withIntermediateDirectories: true)
        let promptFile = promptDir + "/task-\(t.id).txt"
        try text.write(toFile: promptFile, atomically: true, encoding: .utf8)
        guard let exe = Shell.which(tool) else { throw Failure.message("`\(tool)` not found in PATH") }
        let cmd = "cd \(shq(dir)) && \(shq(exe)) \"$(cat \(shq(promptFile)))\""

        let core = Core.shared
        core.q.sync {
            core.launches[dir] = (t.id, now())
            var f: [String: Any] = ["updated_at": now()]
            if isolated { f["worktree"] = dir; f["branch"] = branch; f["base_branch"] = base }
            core.db.update("tasks", id: t.id, f)
            core.addEvent(project: p.id, agent: nil, kind: "workspace",
                          title: "You launched \(tool == "codex" ? "Codex" : "Claude Code") on task #\(t.id) \"\(t.title.trunc(100))\""
                              + (isolated ? " on branch \(branch)" : ""), detail: dir, ref: "\(t.id)")
            core.changed()
        }
        try openTerminal(cmd)
        return isolated ? "Agent launched in \(dir) (branch \(branch))." : "Agent launched in \(dir)."
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func openTerminal(_ command: String) throws {
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if AppSettings.terminalApp == "iTerm" {
            script = """
            tell application "iTerm"
              activate
              set w to (create window with default profile)
              tell current session of w to write text "\(esc)"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
              activate
              do script "\(esc)"
            end tell
            """
        }
        let r = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 20)
        guard r.ok else {
            throw Failure.message("Couldn't open the terminal: \(r.err.trimmed)".trunc(400)
                + (r.err.contains("-1743") ? " — allow AgentBoard to control the terminal in System Settings → Privacy & Security → Automation." : ""))
        }
    }

    // MARK: Review

    /// The branch's committed changes since it left base, plus anything not yet committed in the worktree.
    static func diff(task t: TaskItem, project p: Project) -> String {
        guard !t.branch.isEmpty else { return "" }
        var parts: [String] = []
        let committed = Shell.git(["diff", "--no-color", "--no-ext-diff", "\(t.baseBranch)...\(t.branch)"], cwd: p.path, timeout: 30)
        if committed.ok { parts.append(committed.out) }
        if !t.worktree.isEmpty, FileManager.default.fileExists(atPath: t.worktree) {
            let wip = Shell.git(["diff", "--no-color", "--no-ext-diff", "HEAD"], cwd: t.worktree, timeout: 30)
            if wip.ok, !wip.out.trimmed.isEmpty { parts.append(wip.out) }
            let untracked = Shell.git(["ls-files", "--others", "--exclude-standard"], cwd: t.worktree, timeout: 10)
            for f in untracked.out.split(separator: "\n").prefix(30) {
                let d = Shell.run("/usr/bin/git", ["diff", "--no-color", "--no-index", "/dev/null", String(f)], cwd: t.worktree, timeout: 10)
                parts.append(d.out)
            }
        }
        return parts.joined(separator: "\n")
    }

    static func commits(task t: TaskItem, project p: Project) -> [String] {
        guard !t.branch.isEmpty else { return [] }
        return Shell.git(["log", "--format=%h %s", "\(t.baseBranch)..\(t.branch)"], cwd: p.path, timeout: 15).out
            .split(separator: "\n").map(String.init)
    }

    static func merge(task t: TaskItem, project p: Project) throws -> String {
        let cur = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: p.path)
        guard cur.line == t.baseBranch else {
            throw Failure.message("\(p.path) is currently on branch \(cur.line), but the task branched off \(t.baseBranch). Switch to \(t.baseBranch) and try again.")
        }
        let dirty = Shell.git(["status", "--porcelain", "--untracked-files=no"], cwd: p.path)
        guard dirty.out.trimmed.isEmpty else { throw Failure.message("\(p.path) has uncommitted changes — deal with them first.") }
        if !t.worktree.isEmpty {
            let wip = Shell.git(["status", "--porcelain"], cwd: t.worktree)
            if !wip.out.trimmed.isEmpty { throw Failure.message("The task's worktree has uncommitted changes — ask the agent to commit them.") }
        }
        let r = Shell.git(["merge", "--no-ff", t.branch, "-m", "Merge #\(t.id): \(t.title)"], cwd: p.path, timeout: 60)
        guard r.ok else {
            _ = Shell.git(["merge", "--abort"], cwd: p.path)
            throw Failure.message("Merge failed (conflict?) — aborted.\n\((r.out + r.err).trunc(800))")
        }
        return "Branch \(t.branch) merged into \(t.baseBranch)."
    }

    static func createPR(task t: TaskItem, project p: Project) throws -> String {
        guard let gh = Shell.which("gh") else { throw Failure.message("GitHub CLI (gh) is required") }
        let dir = t.worktree.isEmpty ? p.path : t.worktree
        let push = Shell.git(["push", "-u", "origin", t.branch], cwd: dir, timeout: 120)
        guard push.ok else { throw Failure.message("git push: \(push.err.trimmed)".trunc(600)) }
        let body = (t.details.isEmpty ? "" : t.details + "\n\n") + "Task #\(t.id) from AgentBoard."
        let r = Shell.run(gh, ["pr", "create", "--head", t.branch, "--base", t.baseBranch, "--title", t.title, "--body", body],
                          cwd: dir, timeout: 120)
        guard r.ok else { throw Failure.message("gh pr create: \((r.err + r.out).trimmed)".trunc(600)) }
        return r.out.trimmed
    }

    static func removeWorktree(task t: TaskItem, project p: Project) throws {
        guard !t.worktree.isEmpty else { return }
        if FileManager.default.fileExists(atPath: t.worktree) {
            let r = Shell.git(["worktree", "remove", t.worktree], cwd: p.path, timeout: 60)
            guard r.ok else { throw Failure.message("git worktree remove: \(r.err.trimmed) — it may have uncommitted changes.".trunc(500)) }
        }
        Core.shared.q.sync {
            Core.shared.db.update("tasks", id: t.id, ["worktree": ""])
            Core.shared.changed()
        }
    }
}

// MARK: - Unified diff parsing for the review screen

struct DiffFile: Identifiable, Hashable {
    var path: String
    var lines: [DiffLine]
    var id: String { path }
    var added: Int { lines.filter { $0.kind == .add }.count }
    var removed: Int { lines.filter { $0.kind == .del }.count }
}

struct DiffLine: Identifiable, Hashable {
    enum Kind: Hashable { case add, del, ctx, hunk }
    var id: Int
    var kind: Kind
    var text: String
    var oldNo: Int?
    var newNo: Int?
}

enum DiffParser {
    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var cur: DiffFile?
        var o = 0, n = 0, id = 0
        func flush() { if let c = cur, !c.lines.isEmpty { files.append(c) }; cur = nil }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                flush()
                let path = raw.components(separatedBy: " b/").last ?? raw
                cur = DiffFile(path: path, lines: [])
                continue
            }
            if raw.hasPrefix("+++ ") {
                let p = String(raw.dropFirst(4))
                if p != "/dev/null" { cur?.path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p }
                continue
            }
            if raw.hasPrefix("--- ") || raw.hasPrefix("index ") || raw.hasPrefix("new file") || raw.hasPrefix("deleted file")
                || raw.hasPrefix("similarity") || raw.hasPrefix("rename ") || raw.hasPrefix("old mode") || raw.hasPrefix("new mode") { continue }
            guard cur != nil else { continue }
            id += 1
            if raw.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                let nums = raw.split(separator: " ").dropFirst().prefix(2)
                if let a = nums.first, let b = nums.dropFirst().first {
                    o = Int(a.dropFirst().split(separator: ",").first ?? "0") ?? 0
                    n = Int(b.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                cur!.lines.append(DiffLine(id: id, kind: .hunk, text: raw, oldNo: nil, newNo: nil))
            } else if raw.hasPrefix("+") {
                cur!.lines.append(DiffLine(id: id, kind: .add, text: String(raw.dropFirst()), oldNo: nil, newNo: n)); n += 1
            } else if raw.hasPrefix("-") {
                cur!.lines.append(DiffLine(id: id, kind: .del, text: String(raw.dropFirst()), oldNo: o, newNo: nil)); o += 1
            } else if raw.hasPrefix(" ") {
                cur!.lines.append(DiffLine(id: id, kind: .ctx, text: String(raw.dropFirst()), oldNo: o, newNo: n)); o += 1; n += 1
            }
        }
        flush()
        return files
    }
}
