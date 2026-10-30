import SwiftUI
import MonitorCore

/// Colors from the picked mockup (docs/mockups/combo-window.html), dark and light.
struct Theme: Sendable {
    var bg: Color
    var side: Color
    var tile: Color
    var line: Color
    var fg: Color
    var mut: Color
    var sel: Color
    var isDark: Bool

    static let dark = Theme(bg: Color(hex: 0x0D1117), side: Color(hex: 0x11161D), tile: Color(hex: 0x161B22),
                            line: Color(hex: 0x232A33), fg: Color(hex: 0xE6EDF3), mut: Color(hex: 0x8B949E),
                            sel: Color(hex: 0x1F6FEB, alpha: 0.22), isDark: true)
    static let light = Theme(bg: Color(hex: 0xF6F6F8), side: Color(hex: 0xECECF0), tile: .white,
                             line: Color(hex: 0xE3E3E8), fg: Color(hex: 0x1D1D1F), mut: Color(hex: 0x6E6E73),
                             sel: Color(hex: 0x0A84FF, alpha: 0.14), isDark: false)

    // Series colors (same in both modes, they read on both backgrounds).
    static let cpu = Color(hex: 0x58A6FF)
    static let pCore = Color(hex: 0x58A6FF)
    static let eCore = Color(hex: 0x3FB950)
    static let gpu = Color(hex: 0xA371F7)
    static let temp = Color(hex: 0xFF7B72)
    static let fan = Color(hex: 0x3FB950)
    static let ane = Color(hex: 0xFFA657)
    static let mem = Color(hex: 0xE3B341)
    static let net = Color(hex: 0x39C5CF)
    static let disk = Color(hex: 0xDB61A2)
    static let power = Color(hex: 0xF0883E)
    static let orange = Color(hex: 0xFF9F0A)
    static let good = Color(hex: 0x30D158)
    static let warn = Color(hex: 0xFFD60A)
    static let bad = Color(hex: 0xFF453A)

    /// Blue at 40 C to red at 100 C.
    static func heat(_ c: Double?) -> Color {
        guard let c else { return Color.gray.opacity(0.35) }
        let f = HeatScale.fraction(c)
        return Color(hue: HeatScale.hue(c), saturation: 0.78, brightness: 0.86 + 0.1 * f)
    }

    /// Green, yellow, red for a 0 to 1 load.
    static func load(_ f: Double) -> Color {
        if f > 0.85 { return bad }
        if f > 0.6 { return warn }
        return good
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.dark }
private struct RenderModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    /// True while rendering screenshots: no scroll views, no AppKit controls, history loads synchronously.
    var renderMode: Bool {
        get { self[RenderModeKey.self] }
        set { self[RenderModeKey.self] = newValue }
    }
}

/// Reads the color scheme and hands the matching theme down.
struct Themed: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.theme, scheme == .dark ? .dark : .light)
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
}
