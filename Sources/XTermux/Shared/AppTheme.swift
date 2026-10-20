#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// AppTheme.swift — terminal color themes (SwiftTerm + SwiftUI side).

import SwiftUI

enum TerminalThemeID: String, CaseIterable, Identifiable {
    case midnight
    case daylight
    case solarizedDark
    case dracula

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .midnight: return "Midnight"
        case .daylight: return "Daylight"
        case .solarizedDark: return "Solarized Dark"
        case .dracula: return "Dracula"
        }
    }

    /// Background color for SwiftTerm's native view (`UIColor`).
    func uiBackground() -> UIColor {
        switch self {
        case .midnight: return UIColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        case .daylight: return UIColor(white: 0.97, alpha: 1)
        case .solarizedDark: return UIColor(red: 0.0, green: 0.13, blue: 0.15, alpha: 1)
        case .dracula: return UIColor(red: 0.16, green: 0.16, blue: 0.21, alpha: 1)
        }
    }

    /// Foreground color for SwiftTerm's native view.
    func uiForeground() -> UIColor {
        switch self {
        case .midnight: return UIColor(white: 0.92, alpha: 1)
        case .daylight: return UIColor(white: 0.10, alpha: 1)
        case .solarizedDark: return UIColor(red: 0.83, green: 0.86, blue: 0.84, alpha: 1)
        case .dracula: return UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
        }
    }

    /// SwiftUI accent used by the surrounding chrome so the UI matches.
    var uiAccent: UIColor {
        switch self {
        case .midnight: return UIColor.systemGreen
        case .daylight: return UIColor.systemBlue
        case .solarizedDark: return UIColor.systemTeal
        case .dracula: return UIColor.systemPurple
        }
    }
}
#endif
