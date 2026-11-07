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
}
