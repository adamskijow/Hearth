// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Explicit config mode changes. This keeps setup and doctor assistive without
/// letting Hearth silently flip supervision mode while it is running.
enum ModeCLI {
    static func run(_ args: [String]) -> Never {
        var targetMode: String?
        var daemon = false
        var force = false

        for arg in args {
            switch arg {
            case "managed", "attached":
                if targetMode != nil { usage(exitCode: 2) }
                targetMode = arg
            case "--daemon":
                daemon = true
            case "--force":
                force = true
            case "-h", "--help", "help":
                usage(exitCode: 0)
            default:
                usage(exitCode: 2)
            }
        }

        guard let targetMode else { usage(exitCode: 2) }

        let configURL = daemon ? URL(fileURLWithPath: "/etc/hearth/config.json") : AppPaths.configFile
        if daemon {
            guard geteuid() == 0 else {
                print("Hearth mode")
                print("  FAIL daemon config is root-owned; run with sudo:")
                print("       sudo hearth mode \(targetMode) --daemon")
                exit(1)
            }
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                print("Hearth mode")
                print("  FAIL daemon config not found at \(configURL.path)")
                print("       install the root daemon first, or create that config intentionally")
                exit(1)
            }
        }

        let load = ConfigStore.load(from: configURL, createDefaultIfMissing: !daemon)
        guard !load.isProblem else {
            print("Hearth mode")
            print("  FAIL config: \(load.note ?? "could not be read")")
            exit(1)
        }

        var config = load.config
        let oldMode = config.mode.lowercased()
        config.mode = targetMode

        if targetMode == "attached" && oldMode != "attached" && !force {
            let probe = StatusCLI.probeRunnerPort(config: config)
            guard probe.compatibleRunnerReady else {
                print("Hearth mode")
                print("  FAIL refusing to switch to attached: no compatible \(config.runner) runner is serving at \(config.host):\(config.port).")
                print("       start the runner first, or use `hearth mode attached --force` if you will start it yourself.")
                exit(1)
            }
        }

        guard ConfigStore.save(config, to: configURL) else {
            print("Hearth mode")
            print("  FAIL could not write \(configURL.path)")
            exit(1)
        }

        print("Hearth mode")
        if oldMode == targetMode {
            print("  mode is already \(targetMode) in \(configURL.path)")
        } else {
            print("  set mode to \(targetMode) in \(configURL.path)")
        }

        if targetMode == "attached" {
            print("  Hearth will watch an existing runner; it will not start or stop it.")
        } else {
            print("  Hearth will start and restart the runner it owns.")
            let probe = StatusCLI.probeRunnerPort(config: config)
            if probe.portOccupied && probe.hearthRunner == nil {
                let warning = probe.compatibleRunnerReady
                    ? PreexistingRunner.warning(runner: config.runner, mode: config.mode, foreignRunnerServing: true)
                    : PreexistingRunner.unknownListenerWarning(runner: config.runner, host: config.host, port: config.port)
                if let warning {
                    print("  WARN \(warning)")
                }
            }
        }
        exit(0)
    }

    private static func usage(exitCode: Int32) -> Never {
        print("""
        Usage:
          hearth mode managed [--daemon]
          hearth mode attached [--daemon] [--force]

        managed  Hearth starts and restarts the runner it owns.
        attached Hearth watches a runner started by something else.

        Switching to attached mode refuses by default unless a compatible runner
        is already serving at the configured host and port. Use --force only when
        you intend to start that runner yourself later.
        """)
        exit(exitCode)
    }
}
