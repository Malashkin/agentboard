import AppKit
import SwiftUI

enum ThemePreset: String, CaseIterable, Identifiable {
    case system, midnight, graphite, ocean, forest, sunset, paper, mint
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .midnight: return "Midnight"
        case .graphite: return "Graphite"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .sunset: return "Sunset"
        case .paper: return "Paper"
        case .mint: return "Mint"
        }
    }
    /// background, surface, border, accent (hex), dark?
    var palette: (bg: String, surface: String, border: String, accent: String, dark: Bool?) {
        switch self {
        case .system: return ("", "", "", "", nil)
        case .midnight: return ("0E1220", "171C30", "283253", "7C8CFF", true)
        case .graphite: return ("141414", "1F1F21", "303033", "FF9F0A", true)
        case .ocean: return ("0A1A24", "102836", "1E3E52", "2EC4D6", true)
        case .forest: return ("0E1912", "15251B", "25392C", "4ADE80", true)
        case .sunset: return ("1B1120", "27182C", "3D2644", "FF6B8B", true)
        case .paper: return ("F5F3EE", "FFFFFF", "E3DED4", "2F6BFF", false)
        case .mint: return ("F1F8F4", "FFFFFF", "D9EADF", "12A37F", false)
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { ["system": "Match system", "light": "Light", "dark": "Dark"][rawValue]! }
}

enum Density: String, CaseIterable, Identifiable {
    case compact, regular, spacious
    var id: String { rawValue }
    var label: String { ["compact": "Compact", "regular": "Regular", "spacious": "Spacious"][rawValue]! }
    var padding: CGFloat { self == .compact ? 8 : self == .regular ? 12 : 16 }
    var spacing: CGFloat { self == .compact ? 8 : self == .regular ? 12 : 18 }
    var radius: CGFloat { self == .compact ? 8 : self == .regular ? 11 : 14 }
}

enum CardStyle: String, CaseIterable, Identifiable {
    case filled, outlined, glass
    var id: String { rawValue }
    var label: String { ["filled": "Filled", "outlined": "Outlined", "glass": "Glass"][rawValue]! }
}

/// Look & feel, persisted in UserDefaults. Views observe `ThemeStore.shared` directly so every scene gets it.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private let d = UserDefaults.standard

    @Published var preset: ThemePreset { didSet { d.set(preset.rawValue, forKey: "theme.preset") } }
    @Published var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "theme.appearance") } }
    @Published var density: Density { didSet { d.set(density.rawValue, forKey: "theme.density") } }
    @Published var cardStyle: CardStyle { didSet { d.set(cardStyle.rawValue, forKey: "theme.cardStyle") } }
    @Published var customAccentHex: String { didSet { d.set(customAccentHex, forKey: "theme.accent") } }
    @Published var animations: Bool { didSet { d.set(animations, forKey: "theme.animations") } }
    @Published var pulse: Bool { didSet { d.set(pulse, forKey: "theme.pulse") } }

    init() {
        preset = ThemePreset(rawValue: d.string(forKey: "theme.preset") ?? "") ?? .midnight
        appearance = Appearance(rawValue: d.string(forKey: "theme.appearance") ?? "") ?? .system
        density = Density(rawValue: d.string(forKey: "theme.density") ?? "") ?? .regular
        cardStyle = CardStyle(rawValue: d.string(forKey: "theme.cardStyle") ?? "") ?? .filled
        customAccentHex = d.string(forKey: "theme.accent") ?? ""
        animations = d.object(forKey: "theme.animations") as? Bool ?? true
        pulse = d.object(forKey: "theme.pulse") as? Bool ?? true
    }

    var colorScheme: ColorScheme? {
        if let dark = preset.palette.dark { return dark ? .dark : .light }
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accent: Color {
        if let c = Color(hex: customAccentHex) { return c }
        return Color(hex: preset.palette.accent) ?? .accentColor
    }
    var background: Color? { Color(hex: preset.palette.bg) }
    var surface: Color { Color(hex: preset.palette.surface) ?? Color(nsColor: .controlBackgroundColor) }
    var border: Color { Color(hex: preset.palette.border) ?? Color.primary.opacity(0.09) }

    var accentBinding: Binding<Color> {
        Binding(get: { self.accent }, set: { self.customAccentHex = $0.hex ?? "" })
    }

    /// The app's standard animation, or nil when animations are off.
    func anim(_ a: Animation = .snappy(duration: 0.32)) -> Animation? { animations ? a : nil }

    static func animate(_ body: () -> Void) {
        if shared.animations { withAnimation(.snappy(duration: 0.32), body) } else { body() }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: 1)
    }
    var hex: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

/// Soft pulsing dot for "working" agents.
/// The ring is a Core Animation layer animation: it runs in the window server, so a pulsing dot costs the app nothing
/// per frame. (A SwiftUI `repeatForever` animation re-ran layout of the whole window 60×/s — ~30% CPU with a few agents.)
struct PulseDot: View {
    let color: Color
    var active: Bool
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        ZStack {
            if active && theme.pulse && theme.animations {
                PulseRing(color: NSColor(color)).frame(width: 18, height: 18).allowsHitTesting(false)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
    }
}

private struct PulseRing: NSViewRepresentable {
    let color: NSColor

    final class RingView: NSView {
        let ring = CALayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(ring)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            let d: CGFloat = 8
            ring.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            ring.cornerRadius = d / 2
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        func start(_ color: NSColor) {
            ring.backgroundColor = color.withAlphaComponent(0.35).cgColor
            guard ring.animation(forKey: "pulse") == nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1; scale.toValue = 2.2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9; fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [scale, fade]
            g.duration = 1.4
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.repeatCount = .infinity
            g.isRemovedOnCompletion = false
            ring.add(g, forKey: "pulse")
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { ring.removeAllAnimations(); start(storedColor) }
        }
        var storedColor: NSColor = .systemGreen
    }

    func makeNSView(context: Context) -> RingView {
        let v = RingView(frame: .zero)
        v.storedColor = color
        v.start(color)
        return v
    }

    func updateNSView(_ v: RingView, context: Context) {
        v.storedColor = color
        v.ring.backgroundColor = color.withAlphaComponent(0.35).cgColor
    }
}

/// Lift + shadow on hover.
struct HoverLift: ViewModifier {
    @ObservedObject private var theme = ThemeStore.shared
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover && theme.animations ? 1.012 : 1)
            .shadow(color: .black.opacity(hover ? 0.18 : 0), radius: hover ? 10 : 0, y: hover ? 4 : 0)
            .animation(theme.anim(.spring(response: 0.28, dampingFraction: 0.8)), value: hover)
            .onHover { hover = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}
