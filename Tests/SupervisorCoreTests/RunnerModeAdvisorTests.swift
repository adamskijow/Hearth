// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerModeAdvisorTests {
    @Test func freshSetupUsesAttachedForServingExternalManager() {
        let decision = RunnerModeAdvisor.freshSetupDecision(
            runner: "ollama",
            mode: "managed",
            compatibleRunnerServing: true,
            hearthRunnerServing: false,
            managerLabel: "homebrew.mxcl.ollama"
        )
        if case .switchToAttached(let reason) = decision {
            #expect(reason.contains("homebrew.mxcl.ollama"))
        } else {
            Issue.record("expected setup to switch to attached")
        }
    }

    @Test func freshSetupStopsForLoadedButSilentExternalManager() {
        // A stale launchd job whose runner is not answering must not park Hearth
        // in attached mode: attached never spawns, so nothing would ever start
        // the runner. Setup stops and asks the user to fix or stop the job.
        let decision = RunnerModeAdvisor.freshSetupDecision(
            runner: "ollama",
            mode: "managed",
            compatibleRunnerServing: false,
            hearthRunnerServing: false,
            managerLabel: "homebrew.mxcl.ollama"
        )
        if case .stopForUserChoice(let reason) = decision {
            #expect(reason.contains("homebrew.mxcl.ollama"))
            #expect(reason.contains("brew services stop ollama"))
        } else {
            Issue.record("expected setup to stop for user choice")
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
