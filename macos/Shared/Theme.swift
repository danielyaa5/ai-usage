import SwiftUI
import AIUsageKit

/// The dashboard's colors (static/style.css), for light and dark.
struct Palette {
    let scheme: ColorScheme

    var dark: Bool { scheme == .dark }

    var background: Color { dark ? Color(hex: 0x1A1A19) : Color(hex: 0xFCFCFB) }
    var track: Color { dark ? Color(hex: 0x2C2C29) : Color(hex: 0xE6E5E0) }
    var divider: Color { dark ? Color(hex: 0x2F2F2C) : Color(hex: 0xE2E1DC) }
    var primary: Color { dark ? Color(hex: 0xF0EFEC) : Color(hex: 0x0B0B0B) }
    var secondary: Color { dark ? Color(hex: 0xC3C2B7) : Color(hex: 0x52514E) }
    var muted: Color { dark ? Color(hex: 0x9A998F) : Color(hex: 0x6F6E69) }

    func plan(_ vendor: String) -> Color {
        switch vendor {
        case "anthropic": return dark ? Color(hex: 0xD95926) : Color(hex: 0xEB6834)
        case "openai": return dark ? Color(hex: 0x199E70) : Color(hex: 0x1BAF7A)
        case "google": return dark ? Color(hex: 0x3987E5) : Color(hex: 0x2A78D6)
        default: return muted
        }
    }

    /// Bar fills.
    func fill(_ level: Level) -> Color {
        switch level {
        case .good: return Color(hex: 0x0CA30C)
        case .warning: return Color(hex: 0xFAB219)
        case .critical: return Color(hex: 0xD03B3B)
        }
    }

    /// Text and icons, with enough contrast on the background.
    func text(_ level: Level) -> Color {
        switch level {
        case .good: return dark ? Color(hex: 0x4CC94C) : Color(hex: 0x006300)
        case .warning: return dark ? Color(hex: 0xFAB219) : Color(hex: 0x7A5200)
        case .critical: return dark ? Color(hex: 0xF07A7A) : Color(hex: 0xA42222)
        }
    }

    var stale: Color { text(.warning) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension Level {
    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        }
    }
}
