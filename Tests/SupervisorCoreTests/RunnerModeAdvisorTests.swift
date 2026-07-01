// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerModeAdvisorTests {
    @Test func freshSetupUsesAttachedForKnownExternalManager() {
        let decision = RunnerModeAdvisor.freshSetupDecision(
            runner: "ollama",
            mode: "managed",
            compatibleRunnerServing: false,
            hearthRunnerServing: false,
            managerLabel: "homebrew.mxcl.ollama"
        )
        if case .switchToAttached(let reason) = decision {
            #expect(reason.contains("homebrew.mxcl.ollama"))
        } else {
            Issue.record("expected setup to switch to attached")
        }
    }

    @Test func freshSetupStopsForManualCompatibleRunner() {
        let decision = RunnerModeAdvisor.freshSetupDecision(
            runner: "ollama",
            mode: "managed",
            compatibleRunnerServing: true,
            hearthRunnerServing: false,
            managerLabel: nil
        )
        if case .stopForUserChoice(let reason) = decision {
            #expect(reason.contains("hearth mode attached"))
        } else {
            Issue.record("expected setup to stop for user choice")
        }
    }

    @Test func existingAttachedSetupKeepsCurrentMode() {
        #expect(RunnerModeAdvisor.freshSetupDecision(
            runner: "ollama",
            mode: "attached",
            compatibleRunnerServing: true,
            hearthRunnerServing: false,
            managerLabel: "homebrew.mxcl.ollama"
        ) == .keepCurrent)
    }
}
