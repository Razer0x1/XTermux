#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// AppServices.swift — dependency wiring for the whole app.
//
// The sandbox root is the app's Documents directory: everything the terminal
// can see lives there, enforced by SandboxPath in the core module.

import SwiftUI
import XTermuxCore

/// The app's five tabs, in display order. Shared so any view can navigate
/// without popping to a specific screen (e.g., Home's honest SSH guidance
/// routes to Settings when no profiles exist yet).
enum AppTab: Hashable {
    case terminal, files, packages, projects, settings
}

@MainActor
final class AppServices: ObservableObject {
    let fs: FileSystemService
    let history: HistoryStore
    let localBackend: LocalShellBackend
    let sshProfiles: SSHProfileStore

    // Appearance settings and the honest SSH reconnect preference,
    // persisted with UserDefaults.
    @Published var themeID: TerminalThemeID {
        didSet { UserDefaults.standard.set(themeID.rawValue, forKey: Keys.themeID) }
    }
    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: Keys.fontSize) }
    }
    @Published var sshAutoReconnect: Bool {
        didSet { UserDefaults.standard.set(sshAutoReconnect, forKey: Keys.sshAutoReconnect) }
    }
    /// Single source of truth for the selected tab (bound by ContentView).
    @Published var selectedTab: AppTab = .terminal

    private enum Keys {
        static let themeID = "xtermux.themeID"
        static let fontSize = "xtermux.fontSize"
        static let sshAutoReconnect = "xtermux.sshAutoReconnect"
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fs = FileSystemService(baseURL: documents)
        fs.bootstrapDefaultLayout()
        history = HistoryStore(baseURL: documents)
        localBackend = LocalShellBackend(fs: fs, history: history)
        sshProfiles = SSHProfileStore(documentsDirectory: documents)

        let rawTheme = UserDefaults.standard.string(forKey: Keys.themeID)
        themeID = TerminalThemeID(rawValue: rawTheme ?? "") ?? .midnight
        let storedSize = UserDefaults.standard.double(forKey: Keys.fontSize)
        fontSize = storedSize == 0 ? 12 : max(8, min(28, CGFloat(storedSize)))
        sshAutoReconnect = UserDefaults.standard.bool(forKey: Keys.sshAutoReconnect)
    }
}
#endif
