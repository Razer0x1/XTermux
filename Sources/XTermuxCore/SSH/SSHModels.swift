// SSHModels.swift
// XTermux — data model for SSH host profiles. Secrets are NOT stored here:
// passwords and private keys live in the iOS Keychain (app layer).

import Foundation

public enum SSHAuthKind: String, Codable, Sendable, CaseIterable {
    case password = "Password"
    case rsaKey = "RSA private key"
    case ed25519Key = "Ed25519 private key"
}

public enum SSHTrustPolicy: String, Codable, Sendable, CaseIterable {
    /// Remember/pin expected keys. When empty the session cannot connect
    /// until the user imports the host fingerprint (not implemented yet).
    case pinnedKeys = "Pin known host keys"
    /// Explicitly unverified — user opt-in, clearly flagged in UI.
    case trustOnFirstConnect = "Trust on first connect (unverified)"

    public var isVerified: Bool {
        switch self {
        case .pinnedKeys: return true
        case .trustOnFirstConnect: return false
        }
    }
}

public struct SSHHostProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: SSHAuthKind
    public var trustPolicy: SSHTrustPolicy
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authKind: SSHAuthKind = .password,
        trustPolicy: SSHTrustPolicy = .trustOnFirstConnect,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
        self.trustPolicy = trustPolicy
        self.createdAt = createdAt
    }
}

/// Persists non-secret profile data (JSON in app Documents).
public final class SSHProfileStore: @unchecked Sendable {
    private let url: URL
    private var cache: [SSHHostProfile]?

    public init(documentsDirectory: URL) {
        self.url = documentsDirectory.appendingPathComponent("ssh_profiles.json", isDirectory: false)
    }

    public func load() -> [SSHHostProfile] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: url),
              let profiles = try? JSONDecoder().decode([SSHHostProfile].self, from: data)
        else {
            cache = []
            return []
        }
        cache = profiles
        return profiles
    }

    public func save(_ profiles: [SSHHostProfile]) {
        cache = profiles
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
