// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// One-shot turnkey setup: detect the runner, point the config at it, install the
/// login agent, and wait for the runner to come up under supervision. The single
/// command an app or a person runs to go from nothing to a supervised runner.
enum SetupCLI {
    static func run() -> Never {
        print("Hearth setup")
        var config = ConfigStore.load().config
        let runner = config.runner

        // 1. Detect the runner binary and point the config at it.
        if let detected = RunnerLocator.locate(runner) {
            print("  found \(runner): \(detected)")
            if config.selectedBinaryPath != detected {
                config.setSelectedBinaryPath(detected)
                ConfigStore.save(config)
                print("  set the \(runner) binary path in the config")
            }
        } else {
            print("  \(runner) was not found in the usual locations. Install it (for example")
            print("  `brew install \(runner)`) and re-run, or set the path in Preferences.")
        }

        // 2. Install the login agent.
        let install = AgentInstaller.performInstall()
        for line in install.lines { print("  " + line) }

        // 3. Wait for the runner to answer under supervision.
        print("  waiting up to 60s for the runner to be ready...")
        if StatusCLI.isRunnerReady(config: config, timeout: 60) {
            print("  runner is ready.")
        } else {
            print("  runner did not answer yet; check `hearth doctor` and `hearth logs`.")
        }

        print("")
        print("Done. Hearth runs at login and supervises \(runner).")
        print("Verify with `hearth status` (or `hearth status --json`); remove with `hearth uninstall-agent`.")
        exit(install.ok ? 0 : 1)
    }

}
