#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// SettingsView.swift — appearance, SSH profiles (Keychain secrets), Linux VM
// feasibility, the honest capability matrix, and data management.

import SwiftUI
import XTermuxCore

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var profiles: [SSHHostProfile] = []
    @State private var editorVisible = false
    @State private var editingProfile: SSHHostProfile?
    @AppStorage("xtermux.seenWelcome") private var seenWelcome = true
    @State private var showWelcomeAgain = false
    @State private var clearHistoryConfirm = false
    @StateObject private var vm = VMModel()

    var body: some View {
        NavigationStack {
            List {
                appearanceSection
                sshSection
                linuxVMSection
                capabilitySection
                dataSection
                termuxSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .onAppear(perform: reloadProfiles)
            .sheet(isPresented: $editorVisible, onDismiss: reloadProfiles) {
                SSHProfileEditorView(existing: editingProfile)
            }
            .fullScreenCover(isPresented: $showWelcomeAgain) {
                WelcomeView {
                    showWelcomeAgain = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(uiImage: TerminalTabView.loadLogo())
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityLabel("XTermux logo")
                }
            }
        }
    }

    // MARK: appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $services.themeID) {
                ForEach(TerminalThemeID.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font size")
                    Spacer()
                    Text("\(Int(services.fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospaced())
                }
                Slider(value: $services.fontSize, in: 8...28, step: 1)
                Text("xtermux:~$ ls -la")
                    .font(.system(size: services.fontSize, weight: .regular, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(services.themeID.uiBackground()))
                    )
                    .foregroundStyle(Color(services.themeID.uiForeground()))
            }
        }
    }

    // MARK: ssh

    private var sshSection: some View {
        Section {
            Toggle("Auto-reconnect SSH sessions", isOn: $services.sshAutoReconnect)
            ForEach(profiles) { profile in
                profileRow(profile)
            }
            .onDelete { offsets in
                for offset in offsets {
                    guard let profile = profiles[safe: offset] else { continue }
                    SecretVault.delete(SecretVault.account(for: profile.id))
                }
                var remaining = profiles
                remaining.remove(atOffsets: offsets)
                services.sshProfiles.save(remaining)
                profiles = remaining
            }
            Button {
                editingProfile = nil
                editorVisible = true
            } label: {
                Label("Add SSH profile", systemImage: "plus")
            }

        } header: {
            Text("SSH profiles")
        } footer: {
            Text("Secrets (passwords, keys) are stored in the iOS Keychain - never written to the profile file. Trust-on-first-connect is explicitly marked unverified. Auto-reconnect makes exactly one automatic attempt when a session drops; a session closed with `exit` is never resurrected.")
        }
    }

    private func profileRow(_ profile: SSHHostProfile) -> some View {
        Button {
            editingProfile = profile
            editorVisible = true
        } label: {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(profile.trustPolicy.isVerified ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.callout.weight(.semibold))
                    Text("\(profile.username)@\(profile.host):\(profile.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(profile.trustPolicy.isVerified ? "Verified" : "Unverified")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            (profile.trustPolicy.isVerified ? Color.green : Color.orange).opacity(0.16)
                        )
                    )
                    .foregroundStyle(profile.trustPolicy.isVerified ? Color.green : Color.orange)
            }
        }
    }

    // MARK: linux VM

    private var linuxVMSection: some View {
        Section("Linux VM - honest status") {
            HStack {
                Text("CPU cores")
                Spacer()
                Text("\(vm.config.cpuCores)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Memory")
                Spacer()
                Text("\(vm.config.memoryMB) MB")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Disk image")
                Spacer()
                Text("\(vm.config.diskMB) MB")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("iOS does not grant App Store apps a compliant hypervisor. No Linux guest ships in this build; the settings above are kept so the design is documented, not simulated.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(vm.feasibility.engineConsiderations) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.callout.weight(.semibold))
                    Text("Verdict: \(item.verdict)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: capability matrix

    private var capabilitySection: some View {
        Section("Local backend capabilities") {
            ForEach(services.localBackend.describeCapabilities()) { capability in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: capability.state))
                        .foregroundStyle(color(for: capability.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capability.name)
                            .font(.callout.weight(.semibold))
                        Text(capability.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func icon(for state: BackendCapability.State) -> String {
        switch state {
        case .available: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    private func color(for state: BackendCapability.State) -> Color {
        switch state {
        case .available: return .green
        case .limited: return .orange
        case .unavailable: return .secondary
        }
    }

    // MARK: data

    private var dataSection: some View {
        Section("Data") {
            HStack {
                Text("Sandbox root")
                Spacer()
                Text("Documents (/home/xtermux)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("Show welcome tour again") {
                showWelcomeAgain = true
            }
            Button("Clear command history", role: .destructive) {
                clearHistoryConfirm = true
            }
        }
        .confirmationDialog(
            "Delete the entire persistent command history?",
            isPresented: $clearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                services.history.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: termux inspiration (reference links, honestly unaffiliated)

    private var termuxSection: some View {
        Section {
            ForEach(TermuxReference.projects, id: \.url) { project in
                Link(destination: URL(string: project.url)!) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.callout.weight(.semibold))
                        Text(project.url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(project.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Termux — official project references")
        } footer: {
            Text("These are independent projects by the Termux community, listed for reference. This app borrows ideas — honest package management, a terminal-first design — and is not affiliated with the Termux project.")
        }
    }

    // MARK: about

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "\(ShellInfo.appName) \(ShellInfo.appVersion)")
            LabeledContent("Shell", value: ShellInfo.shellName)
            LabeledContent("Developer", value: ShellInfo.developer)
            Text("\(ShellInfo.appName) is a userspace terminal. It never claims to replace the kernel, never elevates privileges, and never executes foreign binaries on-device. Capabilities that require more are served over SSH or reported honestly. Kernel facts stay read-only: try `kern info` in the terminal.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(ShellInfo.inspirationNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadProfiles() {
        profiles = services.sshProfiles.load()
    }
}

// MARK: termux references

/// The six official Termux project URLs, listed in Settings for reference.
/// This app is inspired by Termux's design and is not affiliated with it.
enum TermuxReference {
    struct Project {
        let name: String
        let url: String
        let note: String
    }

    static let projects: [Project] = [
        Project(
            name: "termux-app",
            url: "https://github.com/termux/termux-app",
            note: "The Android terminal emulator that inspired this app's design."
        ),
        Project(
            name: "termux-packages",
            url: "https://github.com/termux/termux-packages",
            note: "Build system for the Termux package repositories."
        ),
        Project(
            name: "termux.github.io",
            url: "https://github.com/termux/termux.github.io",
            note: "The public Termux wiki repository (wiki.termux.com)."
        ),
        Project(
            name: "termux-tools",
            url: "https://github.com/termux/termux-tools",
            note: "Essential Termux tools and scripts."
        ),
        Project(
            name: "proot-distro",
            url: "https://github.com/termux/proot-distro",
            note: "Manage Linux distributions inside a terminal — no root needed."
        ),
        Project(
            name: "termux (organization)",
            url: "https://github.com/termux",
            note: "All official Termux repositories in one place."
        ),
    ]
}

// MARK: profile editor

struct SSHProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var services: AppServices

    // nil => create new
    let existing: SSHHostProfile?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authKind: SSHAuthKind = .password
    @State private var trustPolicy: SSHTrustPolicy = .trustOnFirstConnect
    @State private var password = ""
    @State private var keyPEM = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Profile name", text: $name)
                    TextField("Host (name or IP)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Authentication") {
                    Picker("Method", selection: $authKind) {
                        ForEach(SSHAuthKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    if authKind == .password {
                        SecureField("Password", text: $password)
                    } else {
                        TextEditor(text: $keyPEM)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 140)
                            .overlay(alignment: .top) {
                                if keyPEM.isEmpty {
                                    Text("Paste the private key, beginning with -----BEGIN ... PRIVATE KEY-----")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    Picker("Host key trust", selection: $trustPolicy) {
                        ForEach(SSHTrustPolicy.allCases, id: \.self) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                }
                Section {
                    Text("Trust-on-first-connect accepts whatever host key the server presents on first contact; pinning known keys happens during the connection step once host-key verification lands in the SSH backend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "New SSH profile" : "Edit SSH profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let existing else { return }
        name = existing.name
        host = existing.host
        port = String(existing.port)
        username = existing.username
        authKind = existing.authKind
        trustPolicy = existing.trustPolicy
        if let secret = SecretVault.load(SecretVault.account(for: existing.id)) {
            if existing.authKind == .password {
                password = secret
            } else {
                keyPEM = secret
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            errorText = "Name, host and username are required."
            return
        }
        guard let parsedPort = Int(port), parsedPort > 0, parsedPort <= 65535 else {
            errorText = "Port must be a number between 1 and 65535."
            return
        }
        let secret = authKind == .password
            ? password.trimmingCharacters(in: .whitespacesAndNewlines)
            : keyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            errorText = authKind == .password ? "Enter the password." : "Paste the private key."
            return
        }

        var profile = existing ?? SSHHostProfile(
            name: trimmedName,
            host: trimmedHost,
            port: parsedPort,
            username: trimmedUser,
            authKind: authKind,
            trustPolicy: trustPolicy
        )
        profile.name = trimmedName
        profile.host = trimmedHost
        profile.port = parsedPort
        profile.username = trimmedUser
        profile.authKind = authKind
        profile.trustPolicy = trustPolicy

        SecretVault.save(secret, for: SecretVault.account(for: profile.id))

        var list = services.sshProfiles.load()
        if let index = list.firstIndex(where: { $0.id == profile.id }) {
            list[index] = profile
        } else {
            list.append(profile)
        }
        services.sshProfiles.save(list)
        dismiss()
    }
}

// MARK: helpers

@MainActor
final class VMModel: ObservableObject {
    @Published private(set) var config = LinuxVMBackend().config
    let feasibility = LinuxVMFeasibility.current

    func update(_ newConfig: VMResourceConfig) {
        config = newConfig
    }
}
#endif
