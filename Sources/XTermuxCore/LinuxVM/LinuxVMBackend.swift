// LinuxVMBackend.swift
// XTermux — honest status of a guest Linux environment inside iOS.
//
// Per the project specification this backend reports ACTUAL, tested reality.
// In this release no Linux guest is integrated or shipped, and the backend
// therefore refuses sessions with an explained, actionable error.

import Foundation

/// User-facing resource settings for a future VM. Kept as real storage +
/// models so Settings can render them, while the engine remains unplugged.
public struct VMResourceConfig: Codable, Equatable, Sendable {
    public var cpuCores: Int
    public var memoryMB: Int
    public var diskMB: Int

    public init(cpuCores: Int = 2, memoryMB: Int = 1024, diskMB: Int = 4096) {
        self.cpuCores = cpuCores
        self.memoryMB = memoryMB
        self.diskMB = diskMB
    }
}

/// Findings from the feasibility investigation of running Linux inside iOS.
/// Surfaced in Settings → Linux so users/engineers see the real analysis.
public struct LinuxVMFeasibility: Sendable, Equatable {
    public struct EngineConsideration: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let verdict: String
        public let detail: String

        public init(name: String, verdict: String, detail: String) {
            self.name = name
            self.verdict = verdict
            self.detail = detail
        }
    }

    public static let current = LinuxVMFeasibility(engineConsiderations: [
        .init(
            name: "QEMU (system, TCG interpreter)",
            verdict: "Rejected for now",
            detail: """
                A no-JIT QEMU TCG build is technically publishable (App Store
                precedent: interpreter-only emulators are approved), but
                QEMU is GPLv2: bundling it makes the whole app GPL, which
                conflicts with typical App Store re-distribution clauses.
                Performance of a pure-TCG interpreter on iPhone is also
                poor (10–20× slower than native).
                """
        ),
        .init(
            name: "Hypervisor.framework guest",
            verdict: "Not possible",
            detail: """
                Hypervisor.framework is not available as a public API on iOS,
                so hardware-accelerated VMs cannot be provided in a
                jailbreak-free App Store app.
                """
        ),
        .init(
            name: "JIT-based engines (WASM, Rosetta-style)",
            verdict: "Rejected",
            detail: """
                Dynamic code translation requires the iOS JIT entitlement,
                which is not granted to App Store apps unless a special
                entitlement (e.g. `com.apple.developer.upscale-vm` is not
                public). No compliant path at this time.
                """
        ),
        .init(
            name: "SSH to a real Linux server",
            verdict: "Shipped",
            detail: """
                For full Linux (bash, python, gcc, apt/apk…), connect an SSH
                session to an authorized server: Terminal → + → SSH.
                """
        ),
    ])
    public let engineConsiderations: [EngineConsideration]

    public init(engineConsiderations: [EngineConsideration]) {
        self.engineConsiderations = engineConsiderations
    }
}

/// Execution backend for the (currently not integrated) Linux VM.
public final class LinuxVMBackend: ExecutionBackend {
    public let config: VMResourceConfig

    public var descriptor: BackendDescriptor {
        BackendDescriptor(
            id: "linuxVM",
            title: "Linux VM",
            subtitle: "not integrated — iOS exposes no compliant hypervisor"
        )
    }

    public var echoMode: EchoMode { .remoteEcho }

    public init(config: VMResourceConfig = VMResourceConfig()) {
        self.config = config
    }

    public func createSession(cols: Int, rows: Int) async throws -> ExecutionSession {
        throw BackendError.unsupported("""
            Linux VM is not integrated in this build of XTermux.

            A compliant hypervisor is not exposed by iOS, and every engine
            investigated (QEMU/TCG, WASM runtimes) is blocked by licensing
            or performance. See Settings → Linux for the full evaluation.

            Full Linux is available today via Terminal → + → SSH session
            to an authorized server.
            """)
    }

    public func describeCapabilities() -> [BackendCapability] {
        [
            BackendCapability(
                name: "Linux VM boot",
                state: .unavailable,
                note: "No public hypervisor API on iOS; guest kernel cannot be launched."
            ),
            BackendCapability(
                name: "Root filesystem (apk/apt)",
                state: .unavailable,
                note: "Depends on a working VM; nothing downloads or mounts until the engine ships."
            ),
            BackendCapability(
                name: "Package management (apk)",
                state: .unavailable,
                note: "Linux executables would not run natively in the iOS sandbox; requires the VM."
            ),
            BackendCapability(
                name: "VM resource settings",
                state: .limited,
                note: "CPU/memory/disk sliders exist but do nothing until an engine is integrated."
            ),
        ]
    }
}
