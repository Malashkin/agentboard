import Foundation

enum CommitMode: String, CaseIterable, Identifiable {
    case off, notify, approve
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Only log to the feed"
        case .notify: return "Notify"
        case .approve: return "Ask for approval"
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
    static let narrator = "narrator"
    static let autoTasks = "autoTasks"
    static let awayDigest = "awayDigest"
    static let awayMinutes = "awayMinutes"
    static let narratorMinutes = "narratorMinutes"
    static let narratorModel = "narratorModel"

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
            narrator: true,
            autoTasks: true,
            awayDigest: true,
            awayMinutes: 20.0,
            narratorMinutes: 2.0,
            narratorModel: "haiku",
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
    static var narrator: Bool { d.bool(forKey: Pref.narrator) }
    static var autoTasks: Bool { d.bool(forKey: Pref.autoTasks) }
    static var awayDigest: Bool { d.bool(forKey: Pref.awayDigest) }
    static var awayMinutes: Double { max(5, d.double(forKey: Pref.awayMinutes)) }
    static var narratorMinutes: Double { max(0.5, d.double(forKey: Pref.narratorMinutes)) }
    static var narratorModel: String { (d.string(forKey: Pref.narratorModel) ?? "").trimmed.isEmpty ? "haiku" : d.string(forKey: Pref.narratorModel)!.trimmed }
    static var worktreeRoot: String {
        if let e = ProcessInfo.processInfo.environment["AGENTBOARD_WORKTREE_ROOT"], !e.isEmpty { return e }
        let v = d.string(forKey: Pref.worktreeRoot) ?? ""
        return v.isEmpty ? NSHomeDirectory() + "/.agentboard/worktrees" : (v as NSString).expandingTildeInPath
    }
}
