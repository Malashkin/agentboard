import Foundation

enum CommitMode: String, CaseIterable, Identifiable {
    case off, notify, approve
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Только записывать в ленту"
        case .notify: return "Уведомлять"
        case .approve: return "Спрашивать одобрение"
        }
    }
}

/// Keys shared with @AppStorage in the settings view.
enum Pref {
    static let port = "port"
    static let commitMode = "commitMode"
    static let approvalTimeout = "approvalTimeout"
    static let injectContext = "injectContext"
    static let conflictWarnings = "conflictWarnings"
    static let notifyCommits = "notifyCommits"
    static let notifyWaiting = "notifyWaiting"
    static let notifyConflicts = "notifyConflicts"
    static let autoSummary = "autoSummary"
    static let summaryHour = "summaryHour"
    static let summaryMinute = "summaryMinute"
    static let exportDir = "exportDir"
    static let staleMinutes = "staleMinutes"
    static let summaryModel = "summaryModel"
    static let permissionsInApp = "permissionsInApp"
    static let permissionTimeout = "permissionTimeout"
    static let blockReservedEdits = "blockReservedEdits"
    static let reservationMinutes = "reservationMinutes"
    static let stuckDetection = "stuckDetection"
    static let stuckNudge = "stuckNudge"
    static let terminalApp = "terminalApp"
    static let worktreeRoot = "worktreeRoot"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            port: 7777,
            commitMode: CommitMode.notify.rawValue,
            approvalTimeout: 300,
            injectContext: true,
            conflictWarnings: true,
            notifyCommits: true,
            notifyWaiting: true,
            notifyConflicts: true,
            autoSummary: true,
            summaryHour: 19,
            summaryMinute: 0,
            exportDir: NSHomeDirectory() + "/Documents/AgentBoard",
            staleMinutes: 30.0,
            summaryModel: "",
            permissionsInApp: true,
            permissionTimeout: 900,
            blockReservedEdits: true,
            reservationMinutes: 30,
            stuckDetection: true,
            stuckNudge: true,
            terminalApp: "Terminal",
            worktreeRoot: NSHomeDirectory() + "/.agentboard/worktrees",
        ])
    }
}

enum AppSettings {
    private static var d: UserDefaults { .standard }
    static var port: Int { let v = d.integer(forKey: Pref.port); return (1024...65535).contains(v) ? v : 7777 }
    static var commitMode: CommitMode { CommitMode(rawValue: d.string(forKey: Pref.commitMode) ?? "") ?? .notify }
    static var approvalTimeout: Double { max(30, d.double(forKey: Pref.approvalTimeout)) }
    static var injectContext: Bool { d.bool(forKey: Pref.injectContext) }
    static var conflictWarnings: Bool { d.bool(forKey: Pref.conflictWarnings) }
    static var notifyCommits: Bool { d.bool(forKey: Pref.notifyCommits) }
    static var notifyWaiting: Bool { d.bool(forKey: Pref.notifyWaiting) }
    static var notifyConflicts: Bool { d.bool(forKey: Pref.notifyConflicts) }
    static var autoSummary: Bool { d.bool(forKey: Pref.autoSummary) }
    static var summaryHour: Int { d.integer(forKey: Pref.summaryHour) }
    static var summaryMinute: Int { d.integer(forKey: Pref.summaryMinute) }
    static var exportDir: String { d.string(forKey: Pref.exportDir) ?? NSHomeDirectory() + "/Documents/AgentBoard" }
    static var staleMinutes: Double { max(5, d.double(forKey: Pref.staleMinutes)) }
    static var summaryModel: String { d.string(forKey: Pref.summaryModel) ?? "" }
    static var permissionsInApp: Bool { d.bool(forKey: Pref.permissionsInApp) }
    static var permissionTimeout: Double { max(30, d.double(forKey: Pref.permissionTimeout)) }
    static var blockReservedEdits: Bool { d.bool(forKey: Pref.blockReservedEdits) }
    static var reservationMinutes: Double { max(1, d.double(forKey: Pref.reservationMinutes)) }
    static var stuckDetection: Bool { d.bool(forKey: Pref.stuckDetection) }
    static var stuckNudge: Bool { d.bool(forKey: Pref.stuckNudge) }
    static var terminalApp: String { d.string(forKey: Pref.terminalApp) ?? "Terminal" }
    static var worktreeRoot: String {
        let v = d.string(forKey: Pref.worktreeRoot) ?? ""
        return v.isEmpty ? NSHomeDirectory() + "/.agentboard/worktrees" : (v as NSString).expandingTildeInPath
    }
}
