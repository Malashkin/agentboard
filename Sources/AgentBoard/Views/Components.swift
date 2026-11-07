import AppKit
import SwiftUI

struct StatusBadge: View {
    let status: AgentStatus
    var body: some View {
        Label(status.label, systemImage: status.icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(status.color.opacity(0.12), in: Capsule())
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
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct Card<Content: View>: View {
    var tint: Color = .clear
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint == .clear ? Color.primary.opacity(0.08) : tint.opacity(0.55), lineWidth: 1))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .accentColor
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView?
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing { trailing }
        }
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
