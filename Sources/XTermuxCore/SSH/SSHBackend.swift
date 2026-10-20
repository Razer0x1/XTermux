// SSHBackend.swift
// XTermux — real remote terminals over SSH (Citadel).
//
// An SSH session is a full PTY (xterm-256color) on the user's own server:
// the remote side echoes, line-edits, and runs real Linux tools. The app
// never pretends any of that runs locally.
//
// Honesty contract:
//   - Secrets come from the iOS Keychain via a provider closure — this file
//     never touches disk for secrets.
//   - Trust-on-first-connect is implemented as "accept any host key" and is
//     LOUDLY flagged in the terminal on every connect; key pinning is
//     planned work and refuses to connect until it lands.
//   - Connection failures surface verbatim, never disguised as "unavailable".

#if canImport(Citadel)
import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

public final class SSHBackend: ExecutionBackend, @unchecked Sendable {
    private let profile: SSHHostProfile
    /// Returns the profile's secret (password or OpenSSH private key text)
    /// from the iOS Keychain. Called at connect time only.
    private let secretProvider: @Sendable () -> String?

    public init(profile: SSHHostProfile, secretProvider: @escaping @Sendable () -> String?) {
        self.profile = profile
        self.secretProvider = secretProvider
    }

    public var descriptor: BackendDescriptor {
        BackendDescriptor(
            id: "ssh",
            title: "SSH remote",
            subtitle: "\(profile.username)@\(profile.host):\(profile.port)"
        )
    }

    /// The remote server echoes typed input; the terminal must not.
    public var echoMode: EchoMode { .remoteEcho }

    public func createSession(cols: Int, rows: Int) async throws -> ExecutionSession {
        guard let secret = secretProvider(), !secret.isEmpty else {
            throw BackendError.connectionFailed(
                "No secret stored for this profile. Add the password or key in Settings > SSH (it is kept in the iOS Keychain)."
            )
        }

        let method: SSHAuthenticationMethod
        switch profile.authKind {
        case .password:
            method = .passwordBased(username: profile.username, password: secret)
        case .rsaKey:
            do {
                method = try .rsa(
                    username: profile.username,
                    privateKey: Insecure.RSA.PrivateKey(sshRsa: secret)
                )
            } catch {
                throw BackendError.connectionFailed(
                    "Could not read the RSA private key. Only OpenSSH-format keys "
                        + "(-----BEGIN OPENSSH PRIVATE KEY-----) are supported; modern ssh-keygen produces that format. (\(error))"
                )
            }
        case .ed25519Key:
            do {
                method = try .ed25519(
                    username: profile.username,
                    privateKey: Curve25519.Signing.PrivateKey(sshEd25519: secret)
                )
            } catch {
                throw BackendError.connectionFailed(
                    "Could not read the Ed25519 private key. Only OpenSSH-format keys "
                        + "(-----BEGIN OPENSSH PRIVATE KEY-----) are supported. (\(error))"
                )
            }
        }

        let validator: SSHHostKeyValidator
        switch profile.trustPolicy {
        case .trustOnFirstConnect:
            // Flagged loudly inside the session on every connect (see SSHSession).
            validator = .acceptAnything()
        case .pinnedKeys:
            throw BackendError.connectionFailed(
                "Host-key pinning is not implemented yet. Re-choose \"Trust on first connect (unverified)\" in Settings, or connect only from a trusted network."
            )
        }

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: profile.host,
                port: profile.port,
                authenticationMethod: method,
                hostKeyValidator: validator,
                reconnect: .never
            )
        } catch {
            throw BackendError.connectionFailed(
                "SSH connection to \(profile.host):\(profile.port) failed: \(error)"
            )
        }
        return SSHSession(client: client, profile: profile, cols: cols, rows: rows)
    }

    public func describeCapabilities() -> [BackendCapability] {
        [
            BackendCapability(
                name: "Interactive remote shell",
                state: .available,
                note: "Full PTY (xterm-256color) over SSH via Citadel. Real Linux, really remote."
            ),
            BackendCapability(
                name: "Password authentication",
                state: .available,
                note: "The password is read from the iOS Keychain at connect time and never written to disk."
            ),
            BackendCapability(
                name: "Key authentication",
                state: .available,
                note: "OpenSSH-format RSA and Ed25519 private keys (ssh-keygen default)."
            ),
            BackendCapability(
                name: "Host key verification",
                state: .limited,
                note: "Trust-on-first-connect only, explicitly flagged in-session. Pinning known host keys is planned."
            ),
            BackendCapability(
                name: "Port/agent forwarding, SFTP",
                state: .unavailable,
                note: "Not implemented in this build."
            ),
        ]
    }
}

/// One live SSH PTY session.
public final class SSHSession: ExecutionSession, @unchecked Sendable {
    public let events: AsyncStream<SessionEvent>
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation

    private let client: SSHClient
    private let profile: SSHHostProfile

    private let lock = NSLock()
    private var writer: TTYStdinWriter?
    private var cols: Int
    private var rows: Int
    private var ioTask: Task<Void, Never>?
    private var started = false

    init(client: SSHClient, profile: SSHHostProfile, cols: Int, rows: Int) {
        self.client = client
        self.profile = profile
        self.cols = cols
        self.rows = rows
        (self.events, self.eventContinuation) = AsyncStream.makeStream()
    }

    /// Opens the PTY and pumps output until the remote side closes it.
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        let initialCols = cols
        let initialRows = rows
        lock.unlock()

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: initialCols,
            terminalRowHeight: initialRows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        let continuation = eventContinuation
        let flagsUnverified = profile.trustPolicy == .trustOnFirstConnect

        continuation.yield(.status(.running))
        if flagsUnverified {
            // Honesty first: the user must know the host key was not checked.
            continuation.yield(.output(Array(
                "\r\n[XTermux] WARNING: host key NOT verified (trust-on-first-connect).\r\n[XTermux] Continue only on networks and servers you trust.\r\n\r\n".utf8
            )))
        }

        ioTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.withPTY(request) { inbound, writer in
                    self.storeWriter(writer)
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer):
                            continuation.yield(.output(Array(buffer.readableBytesView)))
                        case .stderr(let buffer):
                            continuation.yield(.output(Array(buffer.readableBytesView)))
                        }
                    }
                }
                continuation.yield(.status(.ended))
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.status(.disconnected))
                continuation.finish()
            } catch {
                let message = "\r\nssh: session ended: \(error)\r\n"
                continuation.yield(.output(Array(message.utf8)))
                continuation.yield(.status(.disconnected))
                continuation.finish()
            }
        }
    }

    public func sendInput(_ bytes: [UInt8]) {
        guard let writer = currentWriter() else { return }
        let buffer = ByteBuffer(bytes: bytes)
        let box = WriterBox(writer)
        Task {
            try? await box.writer.write(buffer)
        }
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock()
        self.cols = cols
        self.rows = rows
        lock.unlock()
        guard let writer = currentWriter() else { return }
        let box = WriterBox(writer)
        let newCols = cols
        let newRows = rows
        Task {
            try? await box.writer.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    public func terminate() async {
        eventContinuation.finish()
        let task = takeIOTask()
        task?.cancel()
        try? await client.close()
    }

    // MARK: lock-guarded helpers (NSLock may not be used inside async bodies)

    /// Removes and returns the pending IO task, or nil if none is running.
    private func takeIOTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let task = ioTask
        ioTask = nil
        return task
    }

    private func storeWriter(_ newWriter: TTYStdinWriter) {
        lock.lock()
        defer { lock.unlock() }
        writer = newWriter
    }

    private func currentWriter() -> TTYStdinWriter? {
        lock.lock()
        defer { lock.unlock() }
        return writer
    }
}

/// `TTYStdinWriter` is not declared Sendable; this box makes it safe to hand
/// into a `Task` from a lock-guarded snapshot.
private final class WriterBox: @unchecked Sendable {
    let writer: TTYStdinWriter
    init(_ writer: TTYStdinWriter) {
        self.writer = writer
    }
}
#endif
