// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "XTermux",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        // An xtool project contains exactly one library product (the app).
        .library(
            name: "XTermux",
            targets: ["XTermux"]
        ),
    ],
    dependencies: [
        // Terminal emulator: real VT100/xterm rendering. Vendored (see
        // Vendor/SwiftTerm/Package.swift): upstream SwiftTerm cannot build
        // under xtool — its manifest metal-compiles Shaders.metal (impossible
        // on Linux) and excludes the iOS UI sources when the host is Linux.
        .package(path: "Vendor/SwiftTerm"),
        // SSH client for remote terminals (used by the SSH backend).
        // Vendored (see Vendor/Citadel): upstream 0.12.1 declares an
        // `.iOS(.v17)` platform floor, which would force XTermux to 17 — but
        // the SSH client code uses no iOS 17-only API, so the vendored manifest
        // keeps `.iOS(.v16)`. The example target/tests/CI files are stripped.
        .package(path: "Vendor/Citadel"),
        // Citadel 0.12.1 pins this fork of NIOSSH. Declared so XTermuxCore can
        // import NIOSSH (PTY request types) and NIOCore (ByteBuffer) on Apple
        // platforms only; Linux test builds never link them.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        // swift-crypto: imported directly by the SSH backend (curve/ed25519
        // key types). Cryptography is already in the graph via Citadel.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Pure-Swift core: sandbox filesystem, shell engine, backends, models.
        // Platform-only dependencies below are conditioned to Apple platforms,
        // so `swift test` runs on Linux (CI / WSL) without them. The SSH
        // backend (SSH/SSHBackend.swift) is `canImport(Citadel)`-guarded and
        // imports Citadel, Crypto, NIOCore and NIOSSH directly.
        .target(
            name: "XTermuxCore",
            dependencies: [
                .product(
                    name: "Citadel",
                    package: "Citadel",
                    condition: .when(platforms: [.iOS, .macCatalyst, .visionOS, .tvOS])
                ),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.iOS, .macCatalyst, .visionOS, .tvOS])
                ),
                .product(
                    name: "NIOSSH",
                    package: "swift-nio-ssh",
                    condition: .when(platforms: [.iOS, .macCatalyst, .visionOS, .tvOS])
                ),
                .product(
                    name: "NIOCore",
                    package: "swift-nio",
                    condition: .when(platforms: [.iOS, .macCatalyst, .visionOS, .tvOS])
                ),
            ],
            path: "Sources/XTermuxCore"
        ),
        // SwiftUI app shell: terminal views, file manager, packages, projects,
        // settings. Imports SwiftTerm/Citadel on Apple platforms only.
        .target(
            name: "XTermux",
            dependencies: [
                "XTermuxCore",
                .product(
                    name: "SwiftTerm",
                    package: "SwiftTerm",
                    condition: .when(platforms: [.iOS, .macCatalyst, .visionOS, .tvOS])
                ),
                .product(
                    name: "Citadel",
                    package: "Citadel",
                    condition: .when(platforms: [.iOS, .macCatalyst, .visionOS, .tvOS])
                ),
            ],
            path: "Sources/XTermux",
            resources: [
                // The XTermux app logo (bundled for welcome/home/settings and
                // injected as the home-screen icon at IPA packaging time).
                // SwiftPM treats PNGs as resources automatically; declaring the
                // folder explicitly keeps intent obvious.
                .process("Resources"),
            ],
        ),
        .testTarget(
            name: "XTermuxCoreTests",
            dependencies: ["XTermuxCore"],
            path: "Tests/XTermuxCoreTests"
        ),
    ]
)
