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
            return .switchToAttached(reason: "\(runner) is already managed by launchd (\(managerLabel)), so fresh setup will use attached mode and let Hearth watch that existing service.")
        }
        if compatibleRunnerServing && !hearthRunnerServing,
           let warning = PreexistingRunner.warning(runner: runner, mode: mode, foreignRunnerServing: true) {
            return .stopForUserChoice(reason: warning)
        }
        return .keepCurrent
    }
}
