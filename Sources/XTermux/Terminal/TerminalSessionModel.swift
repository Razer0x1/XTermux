#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// TerminalSessionModel.swift — one terminal session shown as one tab.

import Foundation
import SwiftTerm
import XTermuxCore

/// Thread-safe handle for `ExecutionSession.sendInput/resize`, reachable from
/// UIKit delegate callbacks (`send(source:data:)`) that must not block and must
/// not make actor-isolated calls.
final class InputPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var session: ExecutionSession?

    func attach(_ session: ExecutionSession) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    func send(_ bytes: [UInt8]) {
        lock.lock()
        guard let session else { lock.unlock(); return }
        lock.unlock()
        session.sendInput(bytes)
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        guard let session else { lock.unlock(); return }
        lock.unlock()
        session.resize(cols: cols, rows: rows)
    }

    func terminate() async {
        // Detach first so sends during teardown become clean no-ops. The
        // NSLock calls stay in synchronous code: `lock()`/`unlock()` are
        // unavailable from async contexts under Swift 6.
        guard let session = detach() else { return }
        await session.terminate()
    }

    /// Removes and returns the attached session, or nil if nothing is
    /// attached.
    private func detach() -> ExecutionSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return nil }
        self.session = nil
        return session
    }
}

enum SessionKind: Hashable {
    case local
    case ssh(profileID: UUID, profileName: String)

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .ssh(_, let name): return "SSH · \(name)"
        }
    }
}

/// Observable model owned by the UI; drives one `ExecutionSession`.
@MainActor
final class TerminalSessionModel: ObservableObject, Identifiable, Hashable {
    let id = UUID()
    @Published var title: String
    @Published private(set) var status: BackendStatus = .connecting
    @Published private(set) var isClosed = false

    let kind: SessionKind
    let pipe = InputPipe()

    /// Assigned by `TerminalBridgeView` (weak, SwiftUI owns the view).
    weak var terminalView: TerminalView?

    private var runTask: Task<Void, Never>?

    init(kind: SessionKind, title: String) {
        self.kind = kind
        self.title = title
    }

    // Hashable/Equatable requirements are nonisolated; these touch only the
    // immutable Sendable `id`, so the implementations are nonisolated too.
    nonisolated static func == (lhs: TerminalSessionModel, rhs: TerminalSessionModel) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var statusDescription: String {
        switch status {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .running: return "Running"
        case .disconnected: return "Disconnected"
        case .ended: return "Session ended"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        }
    }

    /// When a dropped SSH session should attempt one automatic reconnect.
    /// Set by the session store from Settings before `start`.
    var autoReconnect = false
    /// Fresh backend builder so `restart`/reconnect can create a new backend.
    private var reconnectFactory: (() -> ExecutionBackend)?
    private var lastCols = 80
    private var lastRows = 25
    private var reconnectArmed = false

    var canRestart: Bool { reconnectFactory != nil }

    func start(
        backend: ExecutionBackend,
        cols: Int = 80,
        rows: Int = 25,
        backendFactory: (() -> ExecutionBackend)? = nil
    ) {
        guard runTask == nil else { return }
        if let backendFactory { reconnectFactory = backendFactory }
        lastCols = cols
        lastRows = rows
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await backend.createSession(cols: cols, rows: rows)
                guard !Task.isCancelled else { await session.terminate(); return }
                self.pipe.attach(session)
                self.status = .running
                self.reconnectArmed = false
                for await event in session.events {
                    switch event {
                    case .output(let bytes):
                        self.terminalView?.feed(byteArray: bytes[bytes.startIndex...])
                    case .status(let newStatus):
                        self.status = newStatus
                    }
                }
                if !Task.isCancelled {
                    self.isClosed = true
                    if self.status == .ended {
                        // The peer ended the session deliberately (the user
                        // typed `exit`) — never resurrect that automatically.
                        self.status = .ended
                    } else {
                        self.status = .disconnected
                        self.considerAutomaticReconnect()
                    }
                }
            } catch let error as BackendError {
                self.status = .unavailable(reason: error.errorDescription ?? "connection failed")
                self.terminalView?.feed(text: "\r\n\(error.errorDescription ?? "connection failed")\r\n")
            } catch {
                self.status = .unavailable(reason: error.localizedDescription)
                self.terminalView?.feed(text: "\r\n\(error.localizedDescription)\r\n")
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        pipe.send(bytes)
    }

    func resize(cols: Int, rows: Int) {
        pipe.resize(cols: cols, rows: rows)
    }

    func annotate(_ text: String) {
        terminalView?.feed(text: text)
    }

    func terminate() {
        isClosed = true
        status = .disconnected
        runTask?.cancel()
        Task { await pipe.terminate() }
    }

    /// Closes and starts a fresh session with the same title.
    func restart(with backendFactory: @escaping () -> ExecutionBackend, cols: Int = 80, rows: Int = 25) {
        runTask?.cancel()
        status = .connecting
        isClosed = false
        // Close whatever the old run still owns (dead SSH channel, etc.) so a
        // failed session cannot keep its connection alive in the background.
        Task { await pipe.terminate() }
        runTask = nil
        let revive = backendFactory()
        runTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.runTask = nil // so start's guard lets the revive through
            self.start(backend: revive, cols: cols, rows: rows)
        }
    }

    /// One honest automatic attempt per drop: no loops, no fake progress. If
    /// the attempt fails, the tab stays "Unavailable" and manual restart
    /// remains available.
    private func considerAutomaticReconnect() {
        guard autoReconnect, let factory = reconnectFactory, !reconnectArmed else { return }
        reconnectArmed = true
        annotate("\r\n[xtermux: connection lost — attempting one automatic reconnect…]\r\n")
        restart(with: factory, cols: lastCols, rows: lastRows)
    }

    /// Manual revive (session tab menu / Reconnect button).
    func manualRestart() {
        guard let factory = reconnectFactory else { return }
        runTask?.cancel()
        runTask = nil
        restart(with: factory, cols: lastCols, rows: lastRows)
    }
}
#endif
