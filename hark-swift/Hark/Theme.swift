import SwiftUI

/// 与 style.css 的 CSS 变量一一对应的设计变量（浅色 / 深色两套）。
struct Palette {
    let bg: Color
    let surface: Color
    let surfaceHover: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let accentHover: Color
    let accentSoft: Color
    let danger: Color
    let success: Color
    let warning: Color
    let micColor: Color
    let systemColor: Color
    let bothColor: Color
    let border: Color

    static let light = Palette(
        bg: Color(hex: 0xF5F5F7),
        surface: Color(hex: 0xFFFFFF),
        surfaceHover: Color(hex: 0xF9F9FB),
        textPrimary: Color(hex: 0x1D1D1F),
        textSecondary: Color(hex: 0x6E6E73),
        textTertiary: Color(hex: 0xA1A1A6),
        accent: Color(hex: 0x0071E3),
        accentHover: Color(hex: 0x0077ED),
        accentSoft: Color(hex: 0x0071E3).opacity(0.08),
        danger: Color(hex: 0xFF3B30),
        success: Color(hex: 0x34C759),
        warning: Color(hex: 0xFF9500),
        micColor: Color(hex: 0xFF375F),
        systemColor: Color(hex: 0x32ADE6),
        bothColor: Color(hex: 0xAF52DE),
        border: Color.black.opacity(0.06)
    )

    static let dark = Palette(
        bg: Color(hex: 0x0D0D0D),
        surface: Color(hex: 0x1C1C1E),
        surfaceHover: Color(hex: 0x2C2C2E),
        textPrimary: Color(hex: 0xF5F5F7),
        textSecondary: Color(hex: 0x8E8E93),
        textTertiary: Color(hex: 0x636366),
        accent: Color(hex: 0x0A84FF),
        accentHover: Color(hex: 0x409CFF),
        accentSoft: Color(hex: 0x0A84FF).opacity(0.12),
        danger: Color(hex: 0xFF453A),
        success: Color(hex: 0x30D158),
        warning: Color(hex: 0xFF9F0A),
        micColor: Color(hex: 0xFF375F),
        systemColor: Color(hex: 0x32ADE6),
        bothColor: Color(hex: 0xAF52DE),
        border: Color.white.opacity(0.1)
    )

    static func forTheme(_ theme: ThemeMode, systemDark: Bool) -> Palette {
        switch theme {
        case .light: .light
        case .dark: .dark
        case .system: systemDark ? .dark : .light
        }
    }
}

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension AsrBackend {
    /// 对应 backendMeta[...].color：mlx / SenseVoice 走主题变量，其余是固定色。
    func tintColor(in palette: Palette) -> Color {
        switch self {
        case .mlxQwen3: palette.accent
        case .sensevoice: palette.success
        case .whisperCpp: Color(hex: 0x5856D6)
        case .dashscope: Color(hex: 0xFF6B00)
        case .openaiWhisper: Color(hex: 0x10A37F)
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
