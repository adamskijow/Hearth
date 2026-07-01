// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// One-shot turnkey setup: detect the runner, point the config at it, install the
/// login agent, and wait for the runner to come up under supervision. The single
/// command an app or a person runs to go from nothing to a supervised runner.
enum SetupCLI {
    static func run() -> Never {
        print("Hearth setup")
        let load = ConfigStore.load()
        var config = load.config
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

        let loadedLabels = LaunchdLabels.loaded()
        let portProbe = StatusCLI.probeRunnerPort(config: config)
        if load.createdDefault {
            let managerLabel = RunnerManagerConflict.competingLabel(runner: config.runner, loadedLabels: loadedLabels)
            switch RunnerModeAdvisor.freshSetupDecision(
                runner: config.runner,
                mode: config.mode,
                compatibleRunnerServing: portProbe.compatibleRunnerReady,
                hearthRunnerServing: portProbe.hearthRunner != nil,
                managerLabel: managerLabel
            ) {
            case .switchToAttached(let reason):
                config.mode = "attached"
                ConfigStore.save(config)
                print("  \(reason)")
                print("  set mode to attached in the config")
            case .stopForUserChoice(let reason):
                stopForModeChoice(reason)
            case .keepCurrent:
                break
            }
        } else if let warning = RunnerManagerConflict.warning(
            runner: config.runner,
            mode: config.mode,
            loadedLabels: loadedLabels
        ) {
            stopForModeChoice(warning)
        }

        if let warning = preexistingRunnerWarning(config: config) {
            stopForModeChoice(warning)
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

    private static func preexistingRunnerWarning(config: HearthConfig) -> String? {
        guard config.isManaged else {
            return nil
        }
        let probe = StatusCLI.probeRunnerPort(config: config)
        guard probe.portOccupied, probe.hearthRunner == nil else { return nil }
        if probe.compatibleRunnerReady {
            return PreexistingRunner.warning(
                runner: config.runner,
                mode: config.mode,
                foreignRunnerServing: true
            )
        }
        return PreexistingRunner.unknownListenerWarning(
            runner: config.runner,
            host: config.host,
            port: config.port
        )
    }

    private static func stopForModeChoice(_ warning: String) -> Never {
        // The warning already spells out the case-appropriate options (watch it in
        // attached mode when it is serving, or stop the other manager), so let it
        // stand on its own rather than appending a generic footer that is wrong for
        // the loaded-but-not-serving case.
        print("")
        print("Setup stopped: \(warning)")
        print("Make that choice, then re-run `hearth setup`.")
        exit(1)
    }

}
