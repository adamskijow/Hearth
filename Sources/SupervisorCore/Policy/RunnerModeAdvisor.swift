// SPDX-License-Identifier: MIT

import Foundation

/// Pure guidance for setup-time mode choices. Runtime probing stays in the app;
/// this only turns the observed facts into an explicit action.
public enum RunnerModeAdvisor {
    public enum SetupDecision: Equatable {
        case keepCurrent
        case switchToAttached(reason: String)
        case stopForUserChoice(reason: String)
    }

    public static func freshSetupDecision(runner: String,
                                          mode: String,
                                          compatibleRunnerServing: Bool,
                                          hearthRunnerServing: Bool,
                                          managerLabel: String?) -> SetupDecision {
        guard mode.lowercased() == "managed" else { return .keepCurrent }
        if let managerLabel {
            // Auto-attach only when that manager's runner actually answers.
            // Attached mode never spawns, so attaching to a loaded-but-dead job
            // would park Hearth watching a service nothing ever starts.
            if compatibleRunnerServing {
                return .switchToAttached(reason: "\(runner) is already managed by launchd (\(managerLabel)) and serving, so fresh setup will use attached mode and let Hearth watch that existing service.")
            }
            return .stopForUserChoice(reason: "\(runner) is registered with launchd (\(managerLabel), likely `brew services`) but is not answering on the configured port. Check it with `brew services list`, then either get it serving, or stop it (`brew services stop \(runner)`) so Hearth can manage its own runner.")
        }
        if compatibleRunnerServing && !hearthRunnerServing,
           let warning = PreexistingRunner.warning(runner: runner, mode: mode, foreignRunnerServing: true) {
            return .stopForUserChoice(reason: warning)
        }
        return .keepCurrent
    }
}
