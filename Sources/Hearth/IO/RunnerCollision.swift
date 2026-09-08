// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Check the configured listener before managed supervision starts. Unknown
/// TCP/HTTP services block startup just as compatible foreign runners do.
enum RunnerCollision {
    static func warning(config: HearthConfig) async -> String? {
        guard config.isManaged else { return nil }
        let probe = await Task.detached { StatusCLI.probeRunnerPort(config: config) }.value
        guard probe.portOccupied, probe.hearthRunner == nil else { return nil }
        if probe.compatibleRunnerReady {
            return PreexistingRunner.warning(runner: config.runner, mode: config.mode, foreignRunnerServing: true)
        }
        return PreexistingRunner.unknownListenerWarning(runner: config.runner, host: config.host, port: config.port)
    }
}
