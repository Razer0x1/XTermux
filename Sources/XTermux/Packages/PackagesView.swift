#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// PackagesView.swift — the honest package dashboard.
//
// XTermux never installs executable payloads on iOS. This dashboard reports
// what each tool actually is: a local builtin, something to run on your SSH
// server, something that needs a Linux guest (not integrated), or planned
// work. No fake progress bars, no pretend apt.

import SwiftUI
import XTermuxCore

struct PackagesView: View {
    @EnvironmentObject private var services: AppServices
    @State private var selected: PackageEntry?
    @State private var installed: Set<String> = PkgDB.defaultInstalled
    @State private var moduleError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    honestHeader
                } header: {
                    Text("How packages work here")
                }

                Section {
                    ForEach(SandboxModuleCatalog.modules) { module in
                        moduleRow(module)
                    }
                } header: {
                    Text("Sandbox modules")
                } footer: {
                    Text("These ship inside the app binary; install and remove only record your choice in /.xpkg/installed.json. A removed module's commands fail honestly with exit 127 and a pkg install hint. Changes apply to open terminals immediately.")
                }

                ForEach(groupedKeys, id: \.self) { category in
                    Section {
                        ForEach(grouped[category] ?? []) { entry in
                            Button {
                                selected = entry
                            } label: {
                                row(entry)
                            }
                        }
                    } header: {
                        Text(category)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Packages")
            .onAppear { installed = PkgDB.installedModules(fs: services.fs) }
            .alert("Error", isPresented: Binding(
                get: { moduleError != nil },
                set: { if !$0 { moduleError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(moduleError ?? "")
            }
        }
        .sheet(item: Binding(
            get: { selected },
            set: { _ in selected = nil }
        )) { entry in
            detail(entry)
        }
    }

    private var grouped: [String: [PackageEntry]] {
        Dictionary(grouping: PackageCatalog.entries) { $0.category }
    }

    private var groupedKeys: [String] {
        grouped.keys.sorted()
    }

    private var honestHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nothing here installs binaries into iOS", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text("Local tools are real Swift builtins in this app. Anything needing a real Linux runs on your SSH server. VM-based tools are reported as unavailable - they genuinely are.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func row(_ entry: PackageEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout.weight(.semibold))
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            stateBadge(entry.state)
        }
    }

    // MARK: sandbox module install / remove

    private func moduleRow(_ module: SandboxModule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(module.name)
                        .font(.callout.weight(.semibold))
                    Text("v\(module.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(module.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(module.commands.joined(separator: " "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !installed.contains(module.name) {
                Button("Install") {
                    changeModule(module, adding: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Remove", role: .destructive) {
                    changeModule(module, adding: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func changeModule(_ module: SandboxModule, adding: Bool) {
        let current = PkgDB.installedModules(fs: services.fs)
        let next = adding
            ? current.union([module.name])
            : current.subtracting([module.name])
        do {
            try PkgDB.save(next, fs: services.fs)
            installed = PkgDB.installedModules(fs: services.fs)
        } catch {
            moduleError = String(describing: error)
        }
    }

    private func stateBadge(_ state: PackageState) -> some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(state.color.opacity(0.18)))
            .foregroundStyle(state.color)
    }

    private func detail(_ entry: PackageEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
            Text(entry.name)
                .font(.title3.weight(.bold))
            stateBadge(entry.state)
            Text(entry.summary)
                .font(.body)
            VStack(alignment: .leading, spacing: 6) {
                Label("Runs in: \(entry.target.rawValue)", systemImage: "cpu")
                Text(entry.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
    }
}

extension PackageState {
    var label: String {
        switch self {
        case .available: return "Available"
        case .requiresRemote: return "Needs SSH server"
        case .requiresLinuxVM: return "Needs Linux VM"
        case .notImplemented: return "Planned"
        }
    }

    var color: Color {
        switch self {
        case .available: return .green
        case .requiresRemote: return .blue
        case .requiresLinuxVM: return .orange
        case .notImplemented: return .gray
        }
    }
}
#endif
