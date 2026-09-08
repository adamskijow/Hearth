// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Setup stops at the first failed stage. Check mode verifies the selected
/// client path without installing a login agent or rewriting configuration.
enum SetupCLI {
    struct Options: Sendable {
        var checkOnly = false
        var model: String?

        static func parse(_ args: [String]) -> Options? {
            var options = Options()
            var index = 0
            while index < args.count {
                switch args[index] {
                case "--check": options.checkOnly = true
                case "--model":
                    index += 1
                    guard index < args.count, !args[index].hasPrefix("--"),
                          !args[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    options.model = args[index]
                default: return nil
                }
                index += 1
            }
            return options
        }
    }

    struct Result: Sendable {
        var ok: Bool
        var lines: [String]
    }

    /// Injection keeps setup regression tests away from the user's LaunchAgent.
    struct Dependencies: Sendable {
        var executable: @Sendable (String) -> Bool
        var loadedLabels: @Sendable () -> Set<String>
        var portProbe: @Sendable (HearthConfig) -> StatusCLI.RunnerPortProbe
        var save: @Sendable (HearthConfig) -> Bool
        var install: @Sendable () -> Result
        var ready: @Sendable (HearthConfig, TimeInterval) -> Bool
        var inference: @Sendable (HearthConfig, String) async throws -> Void

        static let live = Dependencies(
            executable: { FileManager.default.isExecutableFile(atPath: ($0 as NSString).expandingTildeInPath) },
            loadedLabels: { LaunchdLabels.loaded() },
            portProbe: { StatusCLI.probeRunnerPort(config: $0) },
            save: { ConfigStore.save($0) },
            install: {
                let result = AgentInstaller.performInstall()
                return Result(ok: result.ok, lines: result.lines)
            },
            ready: { StatusCLI.isRunnerReady(config: $0, timeout: $1) },
            inference: { _ = try await RunnerProbeSetup.test(config: $0, model: $1) }
        )
    }

    static func run(_ args: [String]) -> Never {
        guard let options = Options.parse(args) else {
            print("Usage: hearth setup [--check] [--model MODEL]")
            print("--check verifies the existing client endpoint without installing the login agent.")
            print("--model deliberately runs inference and may load that model.")
            exit(1)
        }
        let load = ConfigStore.load(from: AppPaths.configFile, createDefaultIfMissing: !options.checkOnly)
        print(options.checkOnly ? "Checking the existing client endpoint..." : "Checking configuration and installing the login agent...")
        if options.model != nil { print("The requested inference test may load a model and take a minute or more.") }
        Task {
            let result = await perform(load: load, options: options, dependencies: .live)
            result.lines.forEach { print($0) }
            exit(result.ok ? 0 : 1)
        }
        dispatchMain()
    }

    static func perform(load: ConfigLoad, options: Options, dependencies: Dependencies) async -> Result {
        var lines = [options.checkOnly ? "Hearth setup check" : "Hearth setup"]
        func failed(_ message: String) -> Result { Result(ok: false, lines: lines + ["Setup stopped: " + message]) }
        let blocking = load.blockingDiagnostics()
        guard blocking.isEmpty else { return failed(blocking.map(\.message).joined(separator: "\n")) }
        if options.checkOnly && load.createdDefault {
            return failed("No configuration exists. Run `hearth setup` or save settings in Preferences first.")
        }
        var config = load.config
        if !options.checkOnly {
            let labels = dependencies.loadedLabels()
            let probe = dependencies.portProbe(config)
            if load.createdDefault {
                switch RunnerModeAdvisor.freshSetupDecision(
                    runner: config.runner, mode: config.mode,
                    compatibleRunnerServing: probe.compatibleRunnerReady,
                    hearthRunnerServing: probe.hearthRunner != nil,
                    managerLabel: RunnerManagerConflict.competingLabel(runner: config.runner, loadedLabels: labels)
                ) {
                case .switchToAttached(let reason):
                    config.mode = "attached"
                    guard dependencies.save(config) else { return failed("Could not save attached mode. Check configuration folder permissions.") }
                    lines.append(reason)
                case .stopForUserChoice(let reason): return failed(reason)
                case .keepCurrent: break
                }
            } else if let warning = RunnerManagerConflict.warning(runner: config.runner, mode: config.mode, loadedLabels: labels) {
                return failed(warning)
            }
            if config.isManaged, probe.portOccupied, probe.hearthRunner == nil {
                return failed(probe.compatibleRunnerReady
                    ? (PreexistingRunner.warning(runner: config.runner, mode: config.mode, foreignRunnerServing: true)
                        ?? "A runner already serves this port. Choose attached mode or stop it first.")
                    : PreexistingRunner.unknownListenerWarning(runner: config.runner, host: config.host, port: config.port))
            }
            // Detection only seeds new configs. Never replace a user's custom path.
            if config.isManaged, !dependencies.executable(config.selectedBinaryPath) {
                return failed("The configured \(config.runner) executable is missing or not executable. Install the runner or correct its path in Preferences.")
            }
            let install = dependencies.install()
            lines += install.lines
            guard install.ok else { return failed("The login agent could not be loaded. Correct the installation error, then run setup again.") }
        }

        var clientConfig = config
        clientConfig.port = config.clientPort
        guard dependencies.ready(clientConfig, options.checkOnly ? 1 : 60) else {
            return failed("The client endpoint \(config.clientEndpoint) is not answering. Check the runner and proxy ports with `hearth doctor`.")
        }
        lines.append("API responding at \(config.clientEndpoint).")
        if let model = options.model {
            do { try await dependencies.inference(config, model) }
            catch { return failed("Inference was not verified. \(error.localizedDescription)") }
            lines.append("Completed inference verified through the client endpoint.")
        } else {
            lines.append("Inference has not been tested. Run `hearth setup --check --model MODEL` with your workload model, or use Test in Preferences.")
        }
        lines.append(config.isManaged
            ? "Configured coverage: managed process and API recovery. Check `hearth status` for active ownership and inference recovery eligibility."
            : "Configured coverage: attached observation. Hearth cannot restart the externally managed runner.")
        lines.append("Client traffic visibility is partial; clients can bypass the observed path.")
        return Result(ok: true, lines: lines)
    }
}
