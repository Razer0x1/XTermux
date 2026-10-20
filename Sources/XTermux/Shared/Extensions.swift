#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// Extensions.swift — small shared helpers.

import Foundation
import SwiftUI

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension View {
    /// iOS 16-compatible `onChange`: runs `action` after `value` changes.
    /// The two-parameter closure form `onChange(of:_:)` requires iOS 17;
    /// the single-parameter `perform` form is deprecated there. This shim
    /// picks the right overload at runtime so call sites stay identical.
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, _ in action() }
        } else {
            self.onChange(of: value, perform: { _ in action() })
        }
    }
}
#endif
