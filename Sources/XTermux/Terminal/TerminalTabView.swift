#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// TerminalTabView.swift — multiple sessions, accessory keyboard row, palette.
//
// Session lifecycle lives in `SessionStoreCore` (Linux-tested); this file adds
// view specifics: per-model status observation, auto-close of ended local
// sessions, SSH double-connect dedupe, and the Home/empty state.

import Combine
import SwiftUI
import SwiftTerm
import XTermuxCore

@MainActor
final class SessionStore: ObservableObject {
    private let core = SessionStoreCore<TerminalSessionModel>()
    @Published private(set) var sessions: [TerminalSessionModel] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var showHome = true

    /// Tracks each session's status so a local shell that ends itself (the
    /// user typed `exit`) closes immediately and Home reappears.
    private var statusObservers: [UUID: Task<Void, Never>] = [:]

    var activeSession: TerminalSessionModel? {
        guard !showHome else { return nil }
        return sessions.first { $0.id == activeID }
    }

    func newLocalSession(services: AppServices) {
        let index = sessions.count + 1
        let model = TerminalSessionModel(kind: .local, title: "xsh \(index)")
        model.start(backend: services.localBackend)
        append(model)
    }

    /// Real remote terminal: Citadel PTY over SSH. The secret is pulled from
    /// the Keychain by the backend at connect time. Tapping + twice does not
    /// stack two "Connecting…" tabs for the same profile — the dialing one is
    /// selected instead.
    func newSSHSession(profile: SSHHostProfile, autoReconnect: Bool) {
        if let dialing = sessions.first(where: {
            Self.profileID(of: $0) == profile.id && $0.status == .connecting
        }) {
            select(dialing.id)
            return
        }
        let model = TerminalSessionModel(
            kind: .ssh(profileID: profile.id, profileName: profile.name),
            title: profile.name
        )
        model.autoReconnect = autoReconnect
        model.start(
            backend: SSHBackend(profile: profile, secretProvider: {
                SecretVault.load(SecretVault.account(for: profile.id))
            }),
            backendFactory: {
                SSHBackend(profile: profile, secretProvider: {
                    SecretVault.load(SecretVault.account(for: profile.id))
                })
            }
        )
        append(model)
    }

    private static func profileID(of model: TerminalSessionModel) -> UUID? {
        if case .ssh(let id, _) = model.kind { return id }
        return nil
    }

    func select(_ id: UUID?) {
        core.select(id)
        sync()
    }

    func close(_ model: TerminalSessionModel) {
        core.close(model.id) { $0.terminate() }
        statusObservers[model.id]?.cancel()
        statusObservers[model.id] = nil
        sync()
    }

    func closeAll() {
        core.closeAll { $0.terminate() }
        statusObservers.removeAll()
        sync()
    }

    private func append(_ model: TerminalSessionModel) {
        guard core.append(model) else { return } // duplicate guard
        observe(model)
        sync()
    }

    /// A local shell that reached `.ended` is dead for good — closing it is
    /// the honest lifecycle (it can never be resurrected). SSH ends stay
    /// visible in place, with their live status and the Reconnect affordance.
    private func observe(_ model: TerminalSessionModel) {
        statusObservers[model.id] = Task { [weak self, weak model] in
            guard let model else { return }
            for await status in model.$status.values {
                guard model.kind == .local, status == .ended else { continue }
                self?.close(model)
            }
        }
    }

    /// Mirrors the authoritative core into published state for SwiftUI.
    private func sync() {
        sessions = core.sessions
        activeID = core.selectedID
        showHome = core.showHome
    }

    /// Live status dot color. Chips and sidebar rows observe each model
    /// directly, so an ended session turns gray the moment the backend reports
    /// it — never the stale green from before.
    static func statusColor(_ status: BackendStatus) -> SwiftUI.Color {
        switch status {
        case .running: return .green
        case .connecting: return .orange
        case .disconnected, .ended, .idle: return .gray
        case .unavailable: return .red
        }
    }
}

struct TerminalTabView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.horizontalSizeClass) private var hSize
    @StateObject private var store = SessionStore()
    @State private var paletteVisible = false
    @State private var renameTarget: TerminalSessionModel?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let active = store.activeSession {
                    if hSize == .regular {
                        HStack(spacing: 0) {
                            sidebar
                            Divider()
                            sessionScreen(active)
                        }
                    } else {
                        VStack(spacing: 0) {
                            sessionBar(active)
                            sessionScreen(active)
                        }
                    }
                } else {
                    home
                }
            }
            .background(themeColors.background)
            .sheet(isPresented: $paletteVisible) {
                CommandPaletteView(store: store)
            }
            .alert("Rename session", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Session name", text: $newName)
                Button("Rename") {
                    if let target = renameTarget, !newName.isEmpty {
                        target.title = newName
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.activeSession != nil {
                        Button {
                            store.select(nil)
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                        .accessibilityLabel("Back to session list")

                        Button(role: .destructive) {
                            if let active = store.activeSession {
                                store.close(active)
                            }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Exit session")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: Spacing.md) {
                        Button {
                            paletteVisible = true
                        } label: {
                            Image(systemName: "command.square")
                        }
                        .accessibilityLabel("Command palette")

                        Menu {
                            Button {
                                store.newLocalSession(services: services)
                            } label: {
                                Label("New local session", systemImage: "terminal")
                            }
                            Section("SSH") {
                                sshProfileActions
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New session")
                    }
                }
            }
        }
    }

    // SwiftTerm also exports a Color type, so SwiftUI's must be qualified here.
    private var themeColors: (background: SwiftUI.Color, text: SwiftUI.Color) {
        (SwiftUI.Color(services.themeID.uiBackground()), SwiftUI.Color(services.themeID.uiForeground()))
    }

    @ViewBuilder
    private var sshProfileActions: some View {
        let profiles = services.sshProfiles.load()
        if profiles.isEmpty {
            Text("No SSH profiles yet — create one in Settings")
        } else {
            ForEach(profiles) { profile in
                Button("Connect to \(profile.name)") {
                    store.newSSHSession(profile: profile, autoReconnect: services.sshAutoReconnect)
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { store.activeID },
            set: { store.select($0) }
        )) {
            ForEach(store.sessions) { model in
                SessionRow(model: model, isActive: model.id == store.activeID)
                    .tag(model.id)
            }
            .onDelete { offsets in
                for offset in offsets {
                    if let model = store.sessions[safe: offset] {
                        store.close(model)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 240)
    }

    private func sessionBar(_ active: TerminalSessionModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(store.sessions) { model in
                    SessionChip(
                        model: model,
                        isActive: model.id == active.id,
                        onTap: { store.select(model.id) },
                        onClose: { store.close(model) },
                        onRename: {
                            newName = model.title
                            renameTarget = model
                        },
                        onRestart: model.canRestart ? { model.manualRestart() } : nil
                    )
                }
            }
            .padding(.horizontal, Spacing.sm + 2)
            .padding(.vertical, Spacing.xs + 2)
        }
        .background(.ultraThinMaterial)
    }

    private func sessionScreen(_ active: TerminalSessionModel) -> some View {
        VStack(spacing: 0) {
            if active.canRestart,
               active.status != .running,
               active.status != .connecting {
                Button {
                    active.manualRestart()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(.vertical, Spacing.sm)
            }
            TerminalBridgeView(
                model: active,
                fontSize: services.fontSize,
                theme: services.themeID
            )
            .padding(.horizontal, Spacing.md)
            .onAppear {
                if active.terminalView == nil {
                    store.select(active.id)
                }
            }
            KeyboardAccessoryBar(model: active)
        }
    }

    private var home: some View {
        VStack {
            Spacer(minLength: Spacing.section)
            VStack(spacing: Spacing.base) {
                Image(uiImage: Self.loadLogo())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
                    .shadow(color: SwiftUI.Color.accentColor.opacity(0.4), radius: 12)
                Text("No sessions open")
                    .font(.title3.weight(.semibold))
                Text("Local commands run inside this app's iOS sandbox — no fork/exec, no root. Full Linux is available over SSH.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)
                HStack(spacing: Spacing.md) {
                    Button {
                        store.newLocalSession(services: services)
                    } label: {
                        Label("Local shell", systemImage: "terminal")
                            .frame(minHeight: Metric.controlHeight)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if let profile = services.sshProfiles.load().first {
                            store.newSSHSession(profile: profile, autoReconnect: services.sshAutoReconnect)
                        } else {
                            // Honesty over a dead button: with no profiles the
                            // action is guidance to Settings, not silence.
                            services.selectedTab = .settings
                        }
                    } label: {
                        Label("SSH", systemImage: "network")
                            .frame(minHeight: Metric.controlHeight)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                sshHint
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.xl)
            .background {
                // iOS-26-style frosted glass, built from iOS 16-safe materials.
                RoundedRectangle(cornerRadius: Metric.panelRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, Spacing.pageMargin(horizontalSizeClass: hSize))
            Spacer(minLength: Spacing.section)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sshHint: some View {
        if services.sshProfiles.load().isEmpty {
            Text("No SSH profiles yet — tapping SSH opens Settings to create one.")
        } else {
            Text("Connecting uses your first profile; manage more in Settings.")
        }
    }

    /// Loads the bundled app logo (SwiftPM resource bundle); the empty
    /// fallback keeps the layout intact.
    static func loadLogo() -> UIImage {
        UIImage(named: "applogo.png", in: Bundle.module, compatibleWith: nil)
            ?? UIImage()
    }
}

// MARK: session representables (they observe their own model)

/// Compact chip in the horizontal session bar. `@ObservedObject` per row is
/// what makes status changes render instantly (ended → gray, connecting →
/// orange) instead of waiting for an unrelated store change.
private struct SessionChip: View {
    @ObservedObject var model: TerminalSessionModel
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onRestart: (() -> Void)?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.xs + 2) {
                Circle()
                    .fill(SessionStore.statusColor(model.status))
                    .frame(width: 7, height: 7)
                Text(model.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Metric.cardRadius / 2)
                    .fill(
                        isActive
                            ? SwiftUI.Color.accentColor.opacity(0.28)
                            : SwiftUI.Color.accentColor.opacity(0.10)
                    )
            )
            .contentShape(Rectangle())
        }
        .frame(minHeight: Metric.sessionChipHeight)
        .contextMenu {
            Button("Rename", action: onRename)
            if model.canRestart {
                Button("Restart session", action: onRestart ?? {})
            }
            Button("Close", role: .destructive, action: onClose)
        }
    }
}

/// Sidebar row (iPad / large width) with the same live status observation.
private struct SessionRow: View {
    @ObservedObject var model: TerminalSessionModel
    let isActive: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(SessionStore.statusColor(model.status))
                .frame(width: Spacing.sm, height: Spacing.sm)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(model.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(model.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .opacity(isActive ? 1 : 0.85)
    }
}

// MARK: accessory row

/// Extra keys row: Esc, Tab, Ctrl + Alt latches, arrows, Home/End, the pipes
/// and shell symbols, clear-screen, plus copy/paste. Horizontally scrollable,
/// so it stays usable from SE-class widths to iPad without shrinking targets.
struct KeyboardAccessoryBar: View {
    @ObservedObject var model: TerminalSessionModel
    @State private var ctrlLatched = false
    @State private var altLatched = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                key("esc") { send([0x1b]) }
                key("tab") { send([0x09]) }
                key("ctrl", armed: ctrlLatched) { toggleCtrl() }
                key("alt", armed: altLatched) { altLatched.toggle() }
                key("↑") { send([0x1b, 0x5b, 0x41]) }
                key("↓") { send([0x1b, 0x5b, 0x42]) }
                key("←") { send([0x1b, 0x5b, 0x44]) }
                key("→") { send([0x1b, 0x5b, 0x43]) }
                key("home") { send([0x1b, 0x5b, 0x48]) }
                key("end") { send([0x1b, 0x5b, 0x46]) }
                key("/") { literal("/") }
                key("-") { literal("-") }
                key("|") { literal("|") }
                key("_") { literal("_") }
                key("[") { literal("[") }
                key("]") { literal("]") }
                key("~") { literal("~") }
                key("clr") { send([0x0c]) } // Ctrl-L
                key("paste") { paste() }
            }
            .padding(.horizontal, Spacing.sm + 2)
            .padding(.vertical, Spacing.xs + 2)
        }
        .frame(height: Metric.accessoryBarHeight)
        .background(.ultraThinMaterial)
    }

    /// Sends bytes through the session. While the Alt latch is armed, an ESC
    /// byte is delivered first (xterm Meta semantics — reads as Meta-<key> in
    /// bash/readline) and the latch disarms after exactly one use.
    private func send(_ bytes: [UInt8]) {
        if altLatched {
            model.send([0x1b])
            altLatched = false
        }
        model.send(bytes)
    }

    private func literal(_ text: String) {
        send(Array(text.utf8))
    }

    private func toggleCtrl() {
        ctrlLatched.toggle()
        // SwiftTerm auto-clears controlModifier after the next keystroke.
        model.terminalView?.controlModifier = ctrlLatched
    }

    private func paste() {
        // Paste bypasses the Alt latch on purpose: Meta-paste is not a real
        // terminal expectation, and the raw clipboard text is what matters.
        if let text = UIPasteboard.general.string {
            model.send(Array(text.utf8))
        }
    }

    private func key(_ label: String, armed: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(.callout, design: .monospaced).weight(armed ? .bold : .medium))
                .foregroundStyle(armed ? SwiftUI.Color.accentColor : SwiftUI.Color.primary)
                .frame(minWidth: 40, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(minHeight: Metric.tapTarget - 2)
    }
}

// MARK: command palette

struct CommandPaletteView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let store: SessionStore
    @State private var query = ""

    private var registry: CommandRegistry = {
        let registry = CommandRegistry()
        registry.registerAll()
        return registry
    }()

    private var suggestions: [String] {
        let all = registry.allCommands().map(\.name)
        guard !query.isEmpty else { return all }
        return all.filter { $0.contains(query.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List(suggestions, id: \.self) { name in
                Button {
                    if let model = store.activeSession {
                        model.send(Array("\(name)\n".utf8))
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text("/bin/" + name)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("run")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if suggestions.isEmpty {
                    Text("No matching command")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Command palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Search commands")
        }
        .presentationDetents([.medium, .large])
    }
}

private extension String {
    var utf8Bytes: [UInt8] { Array(utf8) }
}
#endif
