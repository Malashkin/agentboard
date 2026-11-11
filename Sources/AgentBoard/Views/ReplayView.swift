import SwiftUI

/// Step through a session after the fact: every request, command, edit (with its diff), failure and answer,
/// in order, with a slider and play. Answers "what exactly did it do while I was away?" without the transcript.
enum Replay {
    /// Every step of a session, oldest first (the newest `limit`).
    static func steps(agent: String, core: Core = .shared, limit: Int = 2000) -> [EventItem] {
        core.q.sync {
            core.db.query("SELECT * FROM (SELECT * FROM events WHERE agent_id=? ORDER BY created_at DESC, id DESC LIMIT ?) ORDER BY created_at, id",
                          [agent, limit]).map(EventItem.init)
        }
    }

    /// Indices of the steps that start a new request — the chapters of the session.
    static func chapters(_ steps: [EventItem]) -> [Int] {
        steps.indices.filter { steps[$0].kind == "prompt" }
    }

    /// The first step at or after `time` (for "since I left").
    static func index(at time: Double, in steps: [EventItem]) -> Int {
        steps.firstIndex { $0.createdAt >= time } ?? max(0, steps.count - 1)
    }

    /// Files edited from step `from` on, with how many edits each.
    static func changedFiles(_ steps: [EventItem], from: Int) -> [(String, Int)] {
        var counts: [String: Int] = [:], order: [String] = []
        for e in steps.dropFirst(from) where e.kind == "action" {
            for verb in ["editing ", "writing "] where e.title.hasPrefix(verb) || e.title.contains(": " + verb) {
                let path = String(e.title[e.title.range(of: verb)!.upperBound...])
                if counts[path] == nil { order.append(path) }
                counts[path, default: 0] += 1
            }
        }
        return order.map { ($0, counts[$0]!) }
    }
}

struct ReplaySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let agent: Agent
    @State private var steps: [EventItem] = []
    @State private var at = 0.0
    @State private var playing = false
    @State private var loaded = false
    private let tick = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "play.square.stack").font(.title2)
                Text("Replay · \(agent.name)").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else if steps.isEmpty {
                Text("Nothing recorded for this session yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300)
            } else {
                let i = min(Int(at), steps.count - 1)
                let e = steps[i]
                HStack(spacing: 8) {
                    Button { at = max(0, at - 1) } label: { Image(systemName: "backward.frame.fill") }.disabled(i == 0)
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    Button { at = min(Double(steps.count - 1), at + 1) } label: { Image(systemName: "forward.frame.fill") }.disabled(i == steps.count - 1)
                    Slider(value: $at, in: 0...Double(max(1, steps.count - 1)), step: 1)
                    Text("\(i + 1) / \(steps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80)
                }
                HStack(spacing: 6) {
                    Menu("Requests") {
                        ForEach(Replay.chapters(steps), id: \.self) { c in
                            Button("\(Fmt.time(steps[c].createdAt))  \(steps[c].title.oneLine.trunc(70))") { at = Double(c) }
                        }
                    }.fixedSize()
                    Button("Since I was away") {
                        at = Double(Replay.index(at: AwayWatcher.shared.lastAwayStart ?? (Date().timeIntervalSince1970 - 3600), in: steps))
                    }
                    .help("Jump to the first step after you last left the Mac (or an hour ago)")
                    Spacer()
                    Text(Fmt.gitDate.string(from: Date(timeIntervalSince1970: e.createdAt))).font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: e.icon).foregroundStyle(e.color)
                            Text((e.sub.isEmpty ? "" : "↳ \(e.sub): ") + e.title).font(.callout.weight(.medium)).textSelection(.enabled)
                        }
                        ScrollView {
                            DiffText(text: e.detail).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                    }
                    .frame(maxWidth: .infinity)
                    GroupBox("Changed from here on") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Replay.changedFiles(steps, from: i), id: \.0) { f in
                                    HStack {
                                        Text(f.0).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("×\(f.1)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(width: 240)
                }
                .frame(height: 360)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(steps.indices, id: \.self) { k in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(steps[k].color.opacity(k == i ? 1 : 0.45))
                                    .frame(width: steps[k].kind == "prompt" ? 6 : 4, height: k == i ? 22 : 14)
                                    .id(k)
                                    .modifier(PointerCursor())
                                    .onTapGesture { at = Double(k) }
                                    .help(steps[k].title.oneLine.trunc(120))
                            }
                        }
                    }
                    .onChange(of: i) { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
        .padding(20)
        .frame(width: 900)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let s = Replay.steps(agent: agent.id)
                DispatchQueue.main.async {
                    steps = s
                    at = Double(max(0, s.count - 1))
                    loaded = true
                }
            }
        }
        .onReceive(tick) { _ in
            guard playing, !steps.isEmpty else { return }
            if Int(at) >= steps.count - 1 { playing = false } else { at += 1 }
        }
    }
}

/// Detail text; diff lines ("-"/"+") are colored.
struct DiffText: View {
    let text: String
    var body: some View {
        if text.isEmpty {
            Text("No details for this step.").font(.caption).foregroundStyle(.secondary).padding(8)
        } else {
            let isDiff = text.hasPrefix("-") || text.hasPrefix("+")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.caption.monospaced())
                        .foregroundStyle(isDiff && line.hasPrefix("-") ? Color.red : isDiff && line.hasPrefix("+") ? Color.green : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isDiff && line.hasPrefix("-") ? Color.red.opacity(0.07) : isDiff && line.hasPrefix("+") ? Color.green.opacity(0.07) : .clear)
                }
            }
            .textSelection(.enabled)
            .padding(8)
        }
    }
}
