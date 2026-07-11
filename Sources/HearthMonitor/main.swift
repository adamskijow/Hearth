// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import Dispatch

if Array(CommandLine.arguments.dropFirst()) == ["--self-test-keychain"] {
    exit(MonitorKeychainSelfTest.run())
}

if Array(CommandLine.arguments.dropFirst()) == ["--self-test-apple-model"] {
    Task { exit(await AppleModelSelfTest.run()) }
    dispatchMain()
}

if Array(CommandLine.arguments.dropFirst()) == ["--self-test-apple-model-lab"] {
    Task { exit(await AppleModelLabSelfTest.run()) }
    dispatchMain()
}

// Hearth Monitor is intentionally a different executable from full Hearth. The
// App Store target never imports Hearth, HearthSpawn, or any process-management
// adapter. Monitoring behavior is added behind this boundary once the sandboxed
// packaging proof is established.
let application = NSApplication.shared
let delegate = MonitorAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
