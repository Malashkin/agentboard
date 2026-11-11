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
            return Text(Self.unlinked(a))
        }
        return Text(s)
    }

    /// L2: plans and summaries are written by agents/models that may have read injected content, so links are not
    /// clickable; the real address is shown next to the link text ("text (https://…)") and can be copied.
    static func unlinked(_ a: AttributedString) -> AttributedString {
        var out = AttributedString()
        for run in a.runs {
            var piece = AttributedString(a[run.range])
            if let url = run.link {
                piece.link = nil
                piece.underlineStyle = .single
                out.append(piece)
                if String(piece.characters) != url.absoluteString { out.append(AttributedString(" (\(url.absoluteString))")) }
            } else {
                out.append(piece)
            }
        }
        return out
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

// MARK: - Hover feedback for everything clickable
//
// macOS buttons and tappable cards give no sign they can be clicked until you press them. Every clickable thing
// in AgentBoard reacts to the pointer: a highlight under it and the pointing-hand cursor.

/// Pointing-hand cursor while the pointer is over the view (balanced push/pop).
struct PointerCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onHover { h in
                guard h != inside else { return }
                inside = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if inside { NSCursor.pop(); inside = false } }
    }
}

private struct HoverBox<Label: View>: View {
    let label: Label
    let pressed: Bool
    var kind: Kind
    enum Kind { case icon, bordered, prominent, row }
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size

    var body: some View {
        let small = size == .small || size == .mini
        let accent = ThemeStore.shared.accent
        label
            .padding(.horizontal, padH(small))
            .padding(.vertical, padV(small))
            .foregroundStyle(kind == .prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background(RoundedRectangle(cornerRadius: kind == .row ? 6 : 7, style: .continuous).fill(fill(accent)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(kind == .bordered ? Color.secondary.opacity(hover && enabled ? 0.45 : 0.25) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed && enabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .onHover { hover = $0 }
            .modifier(PointerCursor())
    }

    func padH(_ small: Bool) -> CGFloat {
        switch kind { case .icon: return 4; case .row: return 6; default: return small ? 8 : 12 }
    }
    func padV(_ small: Bool) -> CGFloat {
        switch kind { case .icon: return 3; case .row: return 3; default: return small ? 3 : 5 }
    }
    func fill(_ accent: Color) -> Color {
        let h = hover && enabled, p = pressed && enabled
        switch kind {
        case .prominent: return accent.opacity(p ? 0.75 : h ? 0.88 : 1)
        case .bordered: return Color.secondary.opacity(p ? 0.32 : h ? 0.22 : 0.12)
        case .icon, .row: return (kind == .icon ? accent : Color.secondary).opacity(p ? 0.28 : h ? 0.16 : 0)
        }
    }
}

/// Icon-only and text-link buttons: transparent until hovered.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBox(label: configuration.label, pressed: configuration.isPressed, kind: .icon) }
}
/// The default for every button in the app: a light pill that brightens under the pointer.
struct HoverBorderedStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBox(label: configuration.label, pressed: configuration.isPressed, kind: .bordered) }
}
/// The main action of a screen, in the accent color.
struct HoverProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBox(label: configuration.label, pressed: configuration.isPressed, kind: .prominent) }
}
/// Whole rows that act as buttons.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBox(label: configuration.label, pressed: configuration.isPressed, kind: .row) }
}

extension ButtonStyle where Self == HoverButtonStyle { static var hover: HoverButtonStyle { .init() } }
extension ButtonStyle where Self == HoverBorderedStyle { static var hoverBordered: HoverBorderedStyle { .init() } }
extension ButtonStyle where Self == HoverProminentStyle { static var hoverProminent: HoverProminentStyle { .init() } }
extension ButtonStyle where Self == HoverRowStyle { static var hoverRow: HoverRowStyle { .init() } }

/// Tappable cards and rows that aren't Buttons: an accent outline and lift under the pointer.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 12
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ThemeStore.shared.accent.opacity(hover ? 0.55 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            )
            .brightness(hover ? 0.03 : 0)
            .animation(.easeOut(duration: 0.12), value: hover)
            .onHover { hover = $0 }
            .modifier(PointerCursor())
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 12) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius)) }
    /// Every Button below without its own style gets the hover pill.
    func hoverButtons() -> some View { buttonStyle(.hoverBordered) }
}

/// A feed row that expands on click: a soft background under the pointer (only when there is something to show).
struct FeedRowHover: ViewModifier {
    let active: Bool
    @State private var hover = false
    func body(content: Content) -> some View {
        if active {
            content
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hover ? 0.1 : 0)).padding(.horizontal, -6))
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
                .modifier(PointerCursor())
        } else {
            content
        }
    }
}
