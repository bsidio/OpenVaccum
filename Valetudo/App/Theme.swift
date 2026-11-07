import SwiftUI
import UIKit

/// Colours. Surfaces and text use system colours, so dark mode and the Increase
/// Contrast setting work without any extra code. Accents give their own stronger values.
enum Theme {
    private static func color(_ light: UInt32, _ dark: UInt32, stronger: (light: UInt32, dark: UInt32)? = nil) -> Color {
        func make(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            if traits.accessibilityContrast == .high, let stronger {
                return make(isDark ? stronger.dark : stronger.light)
            }
            return make(isDark ? dark : light)
        })
    }

    // Surfaces
    static let mist = Color(uiColor: .systemGroupedBackground)
    static let paper = Color(uiColor: .secondarySystemGroupedBackground)
    static let track = Color(uiColor: .tertiarySystemFill)
    static let hairline = Color(uiColor: .separator)

    // Text
    static let ink = Color(uiColor: .label)
    static let slate = Color(uiColor: .secondaryLabel)
    static let faint = Color(uiColor: .tertiaryLabel)

    // Accent and status
    static let cobalt = color(0x2F45E0, 0x8C9AFF, stronger: (0x2233B8, 0xB3BDFF))
    static let onCobalt = color(0xFFFFFF, 0x0E1420)
    static let green = Color(uiColor: .systemGreen)
    static let amber = color(0x9A5B00, 0xFFC864, stronger: (0x7A4600, 0xFFDB99))
    static let rose = color(0xC22A45, 0xFF8095, stronger: (0x9B1B33, 0xFFADBB))

    // Floor plan
    static let floor = color(0xFFFFFF, 0x2A333E)
    static let wall = color(0x1C2733, 0xDCE4EC)
    static let selected = color(0x8E9BF5, 0x5564E0)
    static let obstacle = color(0xF0A81C, 0xF4BC52)
    static let rooms: [Color] = [
        color(0xBFE3D0, 0x2F5345), color(0xFCE2A9, 0x5C4E2A), color(0xD4CCF5, 0x453E6B),
        color(0xBADDF5, 0x2C4D63), color(0xF7CBD2, 0x5F3942), color(0xD9E6B3, 0x48522C),
        color(0xC8D4E6, 0x3B4759), color(0xF5D3B3, 0x5C4530)
    ]
}
