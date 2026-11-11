import SwiftUI

/// Time spent per client and task, counted from the agents' activity.
struct TimeBreakdown: View {
    @EnvironmentObject var store: Store
    let from: Double
    let to: Double
    let projectId: String?
    var compact = false
    @State private var report = TimeReport(clients: [], totalWall: 0, totalAgent: 0)
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.clients.isEmpty {
                Text("No agent activity yet").foregroundStyle(.secondary).font(.callout)
            } else {
                HStack(spacing: 16) {
                    Label(TimeReport.format(report.totalWall), systemImage: "clock").font(.headline).smoothNumber(Int(report.totalWall / 60))
                        .help("Real time: parallel work of several agents counts once")
                    Text("agent time \(TimeReport.format(report.totalAgent))").font(.caption).foregroundStyle(.secondary)
                        .help("Sum over all agents")
                }
                let maxWall = report.clients.map(\.wall).max() ?? 1
                ForEach(report.clients.prefix(compact ? 6 : 50)) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            if open.contains(c.id) { open.remove(c.id) } else { open.insert(c.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: open.contains(c.id) ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                Text(c.title).lineLimit(1)
                                Spacer()
                                Text(TimeReport.format(c.wall)).font(.callout.monospacedDigit())
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverRow)
                        GeometryReader { g in
                            Capsule().fill(Color.accentColor.opacity(0.7))
                                .frame(width: max(4, g.size.width * c.wall / maxWall))
                        }
                        .frame(height: 4)
                        if open.contains(c.id) {
                            ForEach(c.tasks) { t in
                                HStack {
                                    Text(t.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(TimeReport.format(t.wall)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.leading, 18)
                            }
                        }
                    }
                }
                .feedRowTransition()
                .animateRows(report.clients.map(\.id))
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.lastWork) { load() }
        .onChange(of: from) { load() }
        .onChange(of: projectId) { load() }
    }

    func load() {
        let (f, t, p) = (from, to, projectId)
        Core.shared.q.async {
            let r = Core.shared.timeReport(from: f, to: t, project: p)
            DispatchQueue.main.async { report = r }
        }
    }
}
