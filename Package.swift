// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
//
// Hearth: a background supervisor that keeps a local LLM runner alive on a
// headless Mac. It is an availability layer, not an inference layer.

import PackageDescription
import Foundation

// Swift Testing lives in a developer framework that is not on the default search
// path when only the Command Line Tools are installed (no full Xcode). A headless
// Mac, which is exactly Hearth's target, is usually in that state. Detect the
// Command Line Tools layout and, if present, add the search paths and runtime
// rpaths so a plain `swift test` builds and runs. Harmless when full Xcode is
// installed: `swift test` already works there and the extra rpaths to a missing
// directory are simply ignored.
let testingFrameworkSettings: (swift: [SwiftSetting], linker: [LinkerSetting]) = {
    let base = "/Library/Developer/CommandLineTools/Library/Developer"
    let frameworks = base + "/Frameworks"
    let libs = base + "/usr/lib"
    guard FileManager.default.fileExists(atPath: frameworks + "/Testing.framework") else {
        return ([], [])
    }
    return (
        swift: [.unsafeFlags(["-F", frameworks])],
        linker: [.unsafeFlags([
            "-F", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", libs
        ])]
    )
}()

let package = Package(
    name: "Hearth",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SupervisorCore", targets: ["SupervisorCore"]),
        .executable(name: "Hearth", targets: ["Hearth"])
    ],
    targets: [
        // Pure decision logic. No AppKit, no SwiftUI, no real I/O.
        // Time, processes, HTTP, power, and notifications all sit behind
        // protocols so the whole target is unit testable with fakes.
        .target(
            name: "SupervisorCore"
        ),
        // The deployable menubar agent. Wires SupervisorCore to real I/O.
        .executableTarget(
            name: "Hearth",
            dependencies: ["SupervisorCore"],
            // Info.plist is consumed by scripts/package-app.sh when assembling the
            // .app bundle, not as an SPM resource.
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(
            name: "SupervisorCoreTests",
            dependencies: ["SupervisorCore"],
            swiftSettings: testingFrameworkSettings.swift,
            linkerSettings: testingFrameworkSettings.linker
        )
    ]
)
