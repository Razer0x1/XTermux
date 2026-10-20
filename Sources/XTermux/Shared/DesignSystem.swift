#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// DesignSystem.swift — XTermux's shared spacing/sizing tokens.
//
// Views pull layout numbers from here instead of scattering magic values, so
// the app stays visually consistent from the iPhone 16e to a Pro Max, hold an
// iPad split view, or whatever foldable display Apple ships next — all while
// touching the smallest number of files.

import SwiftUI

/// Vertical/horizontal rhythm, in points.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let base: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let section: CGFloat = 40

    /// Compact phones take ~12 pt page margins; width-regular surfaces ~20 pt.
    static func pageMargin(horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        horizontalSizeClass == .regular ? lg : md
    }
}

/// Component sizing, in points.
enum Metric {
    /// Every interactive element stays reachable on compact screens.
    static let tapTarget: CGFloat = 44
    /// Standard toolbar buttons (with system inset ≈ tapTarget).
    static let toolbarButton: CGFloat = 44
    /// Text fields, input rows, and primary buttons.
    static let controlHeight: CGFloat = 48
    /// Cards and list rows.
    static let cardRadius: CGFloat = 16
    static let rowHeight: CGFloat = 52
    /// Large panels (home card, key rows).
    static let panelRadius: CGFloat = 22
    /// Terminal bars sit between 48–56 pt; the accessory row targets 48.
    static let accessoryBarHeight: CGFloat = 48
    static let sessionChipHeight: CGFloat = 36
}
#endif
