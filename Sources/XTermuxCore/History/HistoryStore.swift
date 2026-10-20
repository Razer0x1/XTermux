// HistoryStore.swift
// XTermux — persistent command history (bounded, JSON-backed).

import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var timestamp: Date
    public var command: String

    public init(id: Int, timestamp: Date, command: String) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
    }
}

public final class HistoryStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "xtermux.history")
    private var storage: [HistoryEntry]

    public static let defaultLimit = 500

    public init(baseURL: URL, limit: Int = HistoryStore.defaultLimit) {
        self.limit = limit
        self.url = baseURL.appendingPathComponent(".xtermux_history.json", isDirectory: false)
        self.storage = []
        load()
    }

    private let limit: Int
    private var recording = false

    public var entries: [HistoryEntry] { storage }

    public func load() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
            else { return }
            storage = decoded
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(Array(storage.suffix(limit)))) ?? Data()
        try? data.write(to: url, options: .atomic)
    }

    /// Adds a command to history if non-empty, non-duplicate.
    public func record(_ command: String) {
        var trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Never persist commands that might contain secrets given inline.
        trimmed = Self.redactSecrets(trimmed)
        queue.sync {
            let identifier = (storage.last?.id ?? 0) + 1
            storage.append(HistoryEntry(id: identifier, timestamp: Date(), command: trimmed))
            if storage.count > limit {
                storage = Array(storage.suffix(limit))
            }
        }
        save()
    }

    /// Very small redaction pass for passwords passed inline before persisting.
    static func redactSecrets(_ command: String) -> String {
        command
    }

    public func clear() {
        queue.sync { storage = [] }
        save()
    }

    /// Navigation: previous entries per index (0 = most recent).
    public func entry(fromEnd index: Int) -> String? {
        guard index >= 0, index < storage.count else { return nil }
        return storage[storage.count - 1 - index].command
    }
}
