// SPDX-License-Identifier: MIT

import AppKit
import SupervisorCore

// Two ways to run:
//  - default: an LSUIElement menubar agent (no Dock icon, no main window).
//  - --headless (or HEARTH_HEADLESS=1): no GUI at all, for a pre login root
//    LaunchDaemon on a Mac where nobody logs in. See deploy/ and the README.
let headless = CommandLine.arguments.contains("--headless")
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
