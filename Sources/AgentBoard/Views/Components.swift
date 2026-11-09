import AppKit
import SwiftUI

struct StatusBadge: View {
    let status: AgentStatus
    var body: some View {
        HStack(spacing: 5) {
            PulseDot(color: status.color, active: status == .working || status == .waiting || status == .stuck)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(status.color.opacity(0.13), in: Capsule())
        .contentTransition(.interpolate)
        .animation(ThemeStore.shared.anim(), value: status)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var icon: String?
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct Card<Content: View>: View {
    var tint: Color = .clear
    @ViewBuilder var content: Content
    @ObservedObject private var theme = ThemeStore.shared
    var body: some View {
        content
            .padding(theme.density.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SurfaceBackground(radius: theme.density.radius, tint: tint))
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    let icon: String
    var color: Color = .accentColor
    @ObservedObject private var theme = ThemeStore.shared
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 30)
                    .symbolEffect(.bounce, value: value)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(value)))
                        .animation(theme.anim(), value: value)
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
        }
        .hoverLift()
    }
}

/// Lightweight Markdown renderer: headings, bullets, quotes, code blocks, inline styles.
struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String), bullet(Int, String), quote(String), code(String), para(String), rule
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var code: [String]?
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" || line == "***" { out.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level, String(line.dropFirst(level)).trimmed))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                let indent = raw.prefix(while: { $0 == " " }).count / 2
                out.append(.bullet(indent, String(line.dropFirst(2))))
            } else if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                let indent = raw.prefix(while: { $0 == " " }).count / 2
                out.append(.bullet(indent, String(line[..<r.upperBound]).trimmed + " " + line[r.upperBound...]))
            } else if line.hasPrefix(">") {
                out.append(.quote(String(line.dropFirst()).trimmed))
            } else {
                out.append(.para(line))
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let l, let t):
                    inline(t).font(l == 1 ? .title.bold() : l == 2 ? .title3.bold() : .headline)
                        .padding(.top, l <= 2 ? 8 : 4)
                case .bullet(let indent, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(t)
                    }.padding(.leading, CGFloat(indent) * 16)
                case .quote(let t):
                    inline(t).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3), alignment: .leading)
                case .code(let t):
                    Text(t).font(.system(.callout, design: .monospaced)).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                case .para(let t):
                    inline(t)
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

extension View {
    /// Digits roll to the new value instead of jumping.
    func smoothNumber<V: Hashable>(_ value: V, _ numeric: Double? = nil) -> some View {
        self.contentTransition(numeric.map { .numericText(value: $0) } ?? .numericText())
            .animation(ThemeStore.shared.anim(), value: value)
    }

    /// Animates a list only when its set of rows changes — not when text inside a row changes.
    func animateRows<ID: Hashable>(_ ids: [ID]) -> some View {
        animation(ThemeStore.shared.anim(), value: ids)
    }

    /// New rows slide in from the top and fade; removed rows fade out.
    func feedRowTransition() -> some View {
        // A short offset, not a slide across the container: rows never travel over other content,
        // and removed rows leave at once instead of lingering mid-animation.
        transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .identity))
    }
}
