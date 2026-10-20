// swift-tools-version:5.9
// Vendored Citadel 0.12.1 (commit ae8562f, orlandos-nl/Citadel, MIT license).
//
// The ONLY functional change versus upstream is the platform declaration:
// upstream pins `.iOS(.v17)`, which conflicts with XTermux's honest iOS 16
// deployment target. The SSH client code uses no iOS 17-only API — it is
// NIO/Foundation code, so `.iOS(.v16)` is safe and truthful.
//
// Also removed (unused by XTermux): the `CitadelServerExample` executable
// target and its ColorizeSwift dependency, the upstream tests, and the
// CI/docker scaffolding.

import PackageDescription

let package = Package(
    name: "Citadel",
    platforms: [
        .macOS(.v14),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Citadel",
            targets: ["Citadel"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.2.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "CCitadelBcrypt"),
        .target(
            name: "Citadel",
            dependencies: [
                .target(name: "CCitadelBcrypt"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
