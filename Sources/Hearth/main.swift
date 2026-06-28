// SPDX-License-Identifier: MIT

import AppKit
import SupervisorCore

// Ways to run:
//  - default: an LSUIElement menubar agent (no Dock icon, no main window).
//  - --headless (or HEARTH_HEADLESS=1): no GUI at all, for a pre login root
//    LaunchDaemon on a Mac where nobody logs in. See deploy/ and the README.
//  - status / logs: one-shot terminal diagnostics that print and exit.
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "status":
    StatusCLI.printStatus()  // exits
case "logs":
    StatusCLI.tailLogs(Array(arguments.dropFirst()))  // exits
case "events":
    StatusCLI.tailEvents(Array(arguments.dropFirst()))  // exits
case "doctor":
    StatusCLI.printDoctor()  // exits
case "--help", "-h", "help":
    StatusCLI.printUsage()
    exit(0)
default:
    let headless = arguments.contains("--headless")
        || ProcessInfo.processInfo.environment["HEARTH_HEADLESS"] == "1"

    if headless {
        HeadlessRunner(config: ConfigStore.load().config).run()
    } else {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
