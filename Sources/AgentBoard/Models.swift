import Foundation
import SwiftUI

struct Project: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var commonDir: String
    var client: String
    var createdAt: Double

    init(_ r: Row) {
        id = r.s("id"); name = r.s("name"); path = r.s("path")
        commonDir = r.s("common_dir"); client = r.s("client"); createdAt = r.d("created_at")
    }
}

enum AgentStatus: String {
    case working, waiting, idle, ended, stale

    var label: String {
        switch self {
        case .working: return "работает"
        case .waiting: return "ждёт вас"
        case .idle: return "свободен"
        case .ended: return "завершён"
        case .stale: return "неактивен"
        }
    }
    var color: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .blue
        case .ended: return .secondary
        case .stale: return .gray
        }
    }
    var icon: String {
        switch self {
        case .working: return "bolt.fill"
        case .waiting: return "hand.raised.fill"
        case .idle: return "checkmark.circle"
        case .ended: return "moon.zzz"
        case .stale: return "pause.circle"
        }
    }
}

struct Agent: Identifiable, Hashable {
    var id: String
    var projectId: String
    var tool: String
    var sessionId: String
    var name: String
    var cwd: String
    var root: String
    var branch: String
    var status: String
    var lastPrompt: String
    var focus: String
    var lastAction: String
    var lastActionAt: Double
    var startedAt: Double
    var lastSeen: Double
    var endedAt: Double?
    var transcriptPath: String
    var tty: String

    init(_ r: Row) {
        tty = r.s("tty")
        id = r.s("id"); projectId = r.s("project_id"); tool = r.s("tool"); sessionId = r.s("session_id")
        name = r.s("name"); cwd = r.s("cwd"); root = r.s("root"); branch = r.s("branch"); status = r.s("status")
        lastPrompt = r.s("last_prompt"); focus = r.s("focus"); lastAction = r.s("last_action")
        lastActionAt = r.d("last_action_at"); startedAt = r.d("started_at"); lastSeen = r.d("last_seen")
        endedAt = r.od("ended_at"); transcriptPath = r.s("transcript_path")
    }

    var toolLabel: String {
        switch tool {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return tool.capitalized
        }
    }
    var toolIcon: String { tool == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle" }

    func displayStatus(staleMinutes: Double, at date: Date = Date()) -> AgentStatus {
        if status == "ended" { return .ended }
        if date.timeIntervalSince1970 - lastSeen > staleMinutes * 60 { return .stale }
        return AgentStatus(rawValue: status) ?? .idle
    }
    func isActive(staleMinutes: Double, at date: Date = Date()) -> Bool {
        let s = displayStatus(staleMinutes: staleMinutes, at: date)
        return s != .ended && s != .stale
    }
}

enum TaskStatus: String, CaseIterable, Identifiable {
    case backlog, in_progress, review, done
    var id: String { rawValue }
    var label: String {
        switch self {
        case .backlog: return "Бэклог"
        case .in_progress: return "В работе"
        case .review: return "На проверке"
        case .done: return "Готово"
        }
    }
    var color: Color {
        switch self {
        case .backlog: return .gray
        case .in_progress: return .green
        case .review: return .orange
        case .done: return .blue
        }
    }
}

struct TaskItem: Identifiable, Hashable {
    var id: Int64
    var projectId: String
    var title: String
    var details: String
    var client: String
    var status: TaskStatus
    var assignee: String?
    var createdBy: String
    var createdAt: Double
    var updatedAt: Double
    var doneAt: Double?

    init(_ r: Row) {
        id = r.i("id"); projectId = r.s("project_id"); title = r.s("title"); details = r.s("details")
        client = r.s("client"); status = TaskStatus(rawValue: r.s("status")) ?? .backlog
        assignee = r.str("assignee"); createdBy = r.s("created_by"); createdAt = r.d("created_at")
        updatedAt = r.d("updated_at"); doneAt = r.od("done_at")
    }
}

struct EventItem: Identifiable, Hashable {
    var id: Int64
    var projectId: String
    var agentId: String?
    var kind: String
    var title: String
    var detail: String
    var client: String
    var ref: String
    var createdAt: Double

    init(_ r: Row) {
        id = r.i("id"); projectId = r.s("project_id"); agentId = r.str("agent_id"); kind = r.s("kind")
        title = r.s("title"); detail = r.s("detail"); client = r.s("client"); ref = r.s("ref")
        createdAt = r.d("created_at")
    }

    /// Low-signal events are hidden from the feed by default.
    var isRoutine: Bool { ["prompt", "turn_done", "session_start", "session_end", "focus", "action"].contains(kind) }

    var icon: String {
        switch kind {
        case "commit": return "checkmark.seal.fill"
        case "commit_request": return "arrow.up.doc"
        case "commit_approved": return "hand.thumbsup.fill"
        case "commit_denied": return "hand.thumbsdown.fill"
        case "commit_timeout": return "clock.badge.exclamationmark"
        case "push": return "icloud.and.arrow.up"
        case "conflict": return "exclamationmark.triangle.fill"
        case "waiting": return "hand.raised.fill"
        case "prompt": return "text.bubble"
        case "turn_done": return "checkmark.circle"
        case "note": return "note.text"
        case "message": return "envelope.fill"
        case "action": return "terminal"
        case "focus": return "scope"
        case "task_created": return "plus.square"
        case "task_claimed": return "person.crop.square"
        case "task_status": return "arrow.right.square"
        case "session_start": return "play.circle"
        case "session_end": return "stop.circle"
        default: return "circle"
        }
    }
    var color: Color {
        switch kind {
        case "commit", "commit_approved": return .green
        case "commit_request", "push": return .purple
        case "commit_denied", "conflict": return .red
        case "waiting", "commit_timeout": return .orange
        case "note": return .yellow
        case "message": return .teal
        case "task_created", "task_claimed", "task_status": return .blue
        default: return .secondary
        }
    }
}

struct FileTouch: Identifiable, Hashable {
    var agentId: String
    var projectId: String
    var path: String
    var count: Int64
    var lastAt: Double
    var id: String { agentId + "|" + path }

    init(_ r: Row) {
        agentId = r.s("agent_id"); projectId = r.s("project_id"); path = r.s("path")
        count = r.i("count"); lastAt = r.d("last_at")
    }
}

struct SummaryItem: Identifiable, Hashable {
    var id: Int64
    var day: String
    var markdown: String
    var source: String
    var createdAt: Double

    init(_ r: Row) {
        id = r.i("id"); day = r.s("day"); markdown = r.s("markdown"); source = r.s("source"); createdAt = r.d("created_at")
    }
}

struct PendingCommit: Identifiable, Hashable {
    var id: String
    var agentId: String
    var agentName: String
    var projectId: String
    var projectName: String
    var command: String
    var gitStatus: String
    var createdAt: Double
    var deadline: Double
}

struct WorktreeInfo: Identifiable, Hashable {
    var path: String
    var branch: String
    var ahead: Int
    var behind: Int
    var changes: [String]
    var id: String { path }
}

struct CommitLine: Identifiable, Hashable {
    var hash: String
    var time: String
    var author: String
    var subject: String
    var id: String { hash }
}

struct GitSnapshot: Hashable {
    var worktrees: [WorktreeInfo] = []
    var todayCommits: [CommitLine] = []
    var error: String?
    var updatedAt: Double = 0
}

struct MessageItem: Identifiable, Hashable {
    var id: Int64
    var projectId: String
    var toAgent: String
    var fromAgent: String?
    var fromLabel: String
    var text: String
    var createdAt: Double
    var deliveredAt: Double?

    init(_ r: Row) {
        id = r.i("id"); projectId = r.s("project_id"); toAgent = r.s("to_agent"); fromAgent = r.str("from_agent")
        fromLabel = r.s("from_label"); text = r.s("text"); createdAt = r.d("created_at"); deliveredAt = r.od("delivered_at")
    }
}
