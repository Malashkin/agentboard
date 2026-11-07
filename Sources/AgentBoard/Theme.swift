import AppKit
import SwiftUI

enum ThemePreset: String, CaseIterable, Identifiable {
    case system, midnight, graphite, ocean, forest, sunset, paper, mint
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Системная"
        case .midnight: return "Полночь"
        case .graphite: return "Графит"
        case .ocean: return "Океан"
        case .forest: return "Лес"
        case .sunset: return "Закат"
        case .paper: return "Бумага"
        case .mint: return "Мята"
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
    var label: String { ["system": "Как в системе", "light": "Светлое", "dark": "Тёмное"][rawValue]! }
}

enum Density: String, CaseIterable, Identifiable {
    case compact, regular, spacious
    var id: String { rawValue }
    var label: String { ["compact": "Компактно", "regular": "Обычно", "spacious": "Просторно"][rawValue]! }
    var padding: CGFloat { self == .compact ? 8 : self == .regular ? 12 : 16 }
    var spacing: CGFloat { self == .compact ? 8 : self == .regular ? 12 : 18 }
    var radius: CGFloat { self == .compact ? 8 : self == .regular ? 11 : 14 }
}

enum CardStyle: String, CaseIterable, Identifiable {
    case filled, outlined, glass
    var id: String { rawValue }
    var label: String { ["filled": "Заливка", "outlined": "Контур", "glass": "Стекло"][rawValue]! }
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
struct PulseDot: View {
    let color: Color
    var active: Bool
    @ObservedObject private var theme = ThemeStore.shared
    @State private var on = false

    var body: some View {
        ZStack {
            if active && theme.pulse && theme.animations {
                Circle().fill(color.opacity(0.35))
                    .scaleEffect(on ? 2.2 : 1)
                    .opacity(on ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: on)
            }
            Circle().fill(color)
        }
        .frame(width: 8, height: 8)
        .onAppear { on = true }
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
