#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// XTermuxApp.swift — XTermux app entry point.

import SwiftUI

@main
struct XTermuxApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(services)
                .tint(.accentColor)
        }
    }
}
#endif
