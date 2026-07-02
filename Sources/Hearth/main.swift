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
    StatusCLI.printStatus(Array(arguments.dropFirst()))  // exits
case "logs":
    StatusCLI.tailLogs(Array(arguments.dropFirst()))  // exits
case "events":
    StatusCLI.tailEvents(Array(arguments.dropFirst()))  // exits
case "metrics":
    StatusCLI.printMetrics()  // exits
case "doctor":
    StatusCLI.printDoctor()  // exits
case "doctor-daemon":
    StatusCLI.printDaemonDoctor()  // exits
case "mode":
    ModeCLI.run(Array(arguments.dropFirst()))  // exits
case "wait-ready":
    StatusCLI.waitReady(Array(arguments.dropFirst()))  // exits
case "update":
    UpdateCLI.run()  // exits
case "setup":
    SetupCLI.run()  // exits
case "install-agent":
    AgentInstaller.install()  // exits
case "uninstall-agent":
    AgentInstaller.uninstall()  // exits
case "--help", "-h", "help":
    StatusCLI.printUsage()
    exit(0)
default:
    // A present first argument that is not a known subcommand and not flag-style
    // is a typo'd command (`hearth statuss`), not a request to launch the app;
    // silently launching the menubar agent from a CLI typo hides the mistake.
    // Flag-style arguments stay exempt: Finder and Xcode launches pass things
    // like -psn_0_... and -NSDocumentRevisionsDebugMode.
    if let first = arguments.first, !first.hasPrefix("-") {
        FileHandle.standardError.write(Data(
            "Hearth: unknown command \"\(first)\". Run `hearth help` for usage.\n".utf8))
        exit(2)
    }

    let headless = arguments.contains("--headless")
        || ProcessInfo.processInfo.environment["HEARTH_HEADLESS"] == "1"

    if headless {
        // Wait as a hot standby if another Hearth already supervises this config,
        // and take over only if it exits, rather than fighting it or respawn-looping
        // under launchd KeepAlive.
        guard SingleInstance.acquire(wait: true, onWait: {
            FileHandle.standardError.write(Data(
                "Hearth: another instance is supervising this config; standing by to take over if it exits.\n".utf8))
        }) else {
            FileHandle.standardError.write(Data(
                "Hearth: could not acquire the single-instance lock; exiting rather than fighting over the runner.\n".utf8))
            exit(1)
        }
        HeadlessRunner(config: ConfigStore.load().config).run()
    } else {
        // The menubar app must not hang waiting; if another Hearth already
        // supervises, bow out rather than starting a second instance that fights it.
        guard SingleInstance.acquire(wait: false) else {
            FileHandle.standardError.write(Data(
                "Hearth is already running; this menubar instance will exit.\n".utf8))
            exit(0)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
