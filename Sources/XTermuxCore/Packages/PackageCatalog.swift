// PackageCatalog.swift
// XTermux — honest package dashboard data.
//
// Nothing here installs executable payloads. "Packages" only means anything
// for a working execution backend; in this release that means SSH-to-server
// helpers run on YOUR remote server, and everything VM-related stays clearly
// marked as unavailable.

import Foundation

public enum PackageTarget: String, Codable, Sendable {
    case localSandbox = "Local sandbox"
    case linuxVM = "Linux VM"
    case sshRemote = "Remote SSH"
    case unsupported = "Unsupported"
}

public enum PackageState: String, Codable, Sendable {
    case available
    case requiresRemote
    case requiresLinuxVM
    case notImplemented
}

public struct PackageEntry: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let category: String
    public let target: PackageTarget
    public let state: PackageState
    public let note: String

    public init(
        name: String,
        summary: String,
        category: String,
        target: PackageTarget,
        state: PackageState,
        note: String
    ) {
        self.name = name
        self.summary = summary
        self.category = category
        self.target = target
        self.state = state
        self.note = note
    }
}

public struct PackageCatalog {
    /// Static catalog. In a future Linux-VM release this becomes a real
    /// repository index fetched from the VM's package manager.
    public static let entries: [PackageEntry] = [
        .init(
            name: "coreutils (local)",
            summary: "ls, cat, grep, cp, mv, rm, find, head, tail, wc and friends",
            category: "Shell",
            target: .localSandbox,
            state: .available,
            note: "Builtin commands executed by the local sandbox backend."
        ),
        .init(
            name: "SSH client",
            summary: "Interactive remote shells over SSH (Citadel/NIOSSH)",
            category: "Connectivity",
            target: .sshRemote,
            state: .requiresRemote,
            note: "Requires an SSH profile and an authorized server."
        ),
        .init(
            name: "git",
            summary: "Version control",
            category: "Development",
            target: .sshRemote,
            state: .requiresRemote,
            note: "Run on your server via SSH (`git clone …`). Not executable in the iOS sandbox."
        ),
        .init(
            name: "python3",
            summary: "Python interpreter",
            category: "Languages",
            target: .linuxVM,
            state: .requiresLinuxVM,
            note: "Blocked until a compliant VM engine is integrated (see Settings → Linux)."
        ),
        .init(
            name: "node",
            summary: "Node.js runtime",
            category: "Languages",
            target: .linuxVM,
            state: .requiresLinuxVM,
            note: "Blocked until a compliant VM engine is integrated."
        ),
        .init(
            name: "gcc / clang",
            summary: "C/C++ toolchains",
            category: "Languages",
            target: .linuxVM,
            state: .requiresLinuxVM,
            note: "Blocked until a compliant VM engine is integrated."
        ),
        .init(
            name: "apk",
            summary: "Alpine package manager",
            category: "System",
            target: .linuxVM,
            state: .requiresLinuxVM,
            note: "Alpine guest only; never installs Linux executables into the iOS sandbox."
        ),
        .init(
            name: "bash",
            summary: "GNU bash",
            category: "Shell",
            target: .linuxVM,
            state: .requiresLinuxVM,
            note: "Local sessions use the builtin XTerm shell; bash requires the VM."
        ),
    ]
}
