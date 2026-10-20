// swift-tools-version:6.0
//
// VENDORED for XTermux — patched from SwiftTerm v1.20.0 (5d14406).
// Reasons for the patch (upstream SwiftTerm cannot build under xtool, which
// cross-compiles for iPhoneOS from a Linux host):
//
//  1. Shaders.metal is COPIED as a plain resource instead of metal-compiled:
//     there is no `metal` compiler that runs on Linux, and SwiftTerm's own
//     renderer already falls back to runtime source compilation
//     (MetalTerminalRenderer.makeLibrary → device.makeLibrary(source:)).
//     The Metal renderer is opt-in anyway; CoreGraphics rendering is the default.
//  2. Apple/ and iOS/ sources are KEPT when the host is Linux, because the
//     destination (iPhoneOS) provides CoreText/UIKit/Metal from the Darwin
//     SDK. Only the AppKit-only Mac/ directory is excluded.
//  3. Termcast, SwiftTermFuzz, tests, benchmarks and the docc/argument-parser
//     dependencies are dropped — XTermux consumes only the SwiftTerm library.

import PackageDescription
import Foundation

#if os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
// Linux hosts may be cross-compiling for iOS (xtool + Darwin SDK): keep
// Apple/, iOS/ AND Mac/. The Mac/ sources are internally `#if os(macOS)`-guarded
// (only MacAccessibilityService.swift is unconditional, and it is
// Foundation-only) — upstream macOS-host iOS builds include them as well.
let platformExcludes: [String] = []
#endif

let buildInfoTargets: [Target] = [
    .executableTarget(
        name: "SwiftTermBuildInfoGenerator",
        path: "Sources/SwiftTermBuildInfoGenerator"
    ),
    .plugin(
        name: "SwiftTermBuildInfoPlugin",
        capability: .buildTool(),
        dependencies: ["SwiftTermBuildInfoGenerator"]
    )
]

let products: [Product] = [
    .library(
        name: "SwiftTerm",
        targets: ["SwiftTerm"]
    ),
]

let targets: [Target] = [
    .target(
        name: "SwiftTerm",
        path: "Sources/SwiftTerm",
        exclude: platformExcludes + ["Mac/README.md"],
        resources: [
            // Copied verbatim (NOT .process): no metalc invocation. The
            // renderer compiles this source at runtime if Metal is enabled.
            .copy("Apple/Metal/Shaders.metal")
        ],
        plugins: [
            .plugin(name: "SwiftTermBuildInfoPlugin")
        ]
    )
] + buildInfoTargets

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
