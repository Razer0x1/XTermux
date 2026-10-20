// ExecutionBackend.swift
// XTermux — pluggable execution environments.
//
// XTermux runs commands in three clearly separated environments:
//
//   1. local    — commands executed inside the iOS app sandbox by the app
//                 itself (no subprocesses, no fork/exec, no root).
//   2. linuxVM  — an optional guest Linux kernel in a VM. Investigated and
//                 documented; see LinuxVMBackend for the honest status on iOS.
//   3. ssh      — a real remote machine (Linux by default) over SSH.
//
// The app NEVER provides or claims root on iOS and NEVER replaces XNU.

import Foundation

public enum BackendStatus: Sendable, Equatable {
    case idle
    case connecting
    case running
    case disconnected
    /// The peer ended the session on purpose (PTY closed cleanly, for example
    /// after the user typed `exit`). Distinct from `disconnected` (transport
    /// failed mid-session) so UIs can decide whether reconnecting is safe.
    case ended
    case unavailable(reason: String)
}

public enum SessionEvent: Sendable {
    /// Terminal-shaped bytes to feed straight to the emulator screen.
    case output([UInt8])
    case status(BackendStatus)
}

/// One live terminal session inside a backend.
public protocol ExecutionSession: AnyObject, Sendable {
    /// Stream of terminal bytes / status changes.
    var events: AsyncStream<SessionEvent> { get }

    /// Raw bytes coming from the user (keyboard, accessory keys, paste).
    func sendInput(_ bytes: [UInt8])

    /// Terminal (re)size in character cells.
    func resize(cols: Int, rows: Int)

    /// Close the session.
    func terminate() async
}

/// How the session presents typed input on screen.
public enum EchoMode: Sendable {
    /// The backend itself echoes typed bytes (local sandbox shell).
    case localEcho
    /// The remote peer echoes (SSH servers do this).
    case remoteEcho
}

/// Capability reported by a backend for the Settings capability matrix.
public struct BackendCapability: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case available
        case limited
        case unavailable
    }

    public var id: String { name }
    public var name: String
    public var state: State
    public var note: String

    public init(name: String, state: State, note: String) {
        self.name = name
        self.state = state
        self.note = note
    }
}

public struct BackendDescriptor: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String

    public init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public protocol ExecutionBackend: AnyObject, Sendable {
    var descriptor: BackendDescriptor { get }
    var echoMode: EchoMode { get }

    /// Create (and connect) a live session. Throws an honest, user-readable
    /// error when this backend is unavailable on the current device.
    func createSession(cols: Int, rows: Int) async throws -> ExecutionSession

    /// Capabilities for the honest status matrix in Settings.
    func describeCapabilities() -> [BackendCapability]
}

public enum BackendError: LocalizedError, Sendable {
    case unsupported(String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .connectionFailed(let message): return message
        }
    }
}
