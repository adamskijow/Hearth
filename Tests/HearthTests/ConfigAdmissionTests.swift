// SPDX-License-Identifier: MIT

import SupervisorCore
import Testing
@testable import Hearth

struct ConfigAdmissionTests {
    @Test func malformedConfigIsAlwaysBlocking() {
        let load = ConfigLoad(
            config: HearthConfig(),
            note: "Config could not be read.",
            isProblem: true,
            createdDefault: false)
        #expect(load.blockingDiagnostics().map(\.message) == ["Config could not be read."])
    }

    @Test func unknownRunnerAndModeCannotFallThroughToActiveDefaults() {
        let load = ConfigLoad(
            config: HearthConfig(runner: "olama", mode: "attched"),
            note: nil,
            isProblem: false,
            createdDefault: false)
        let messages = load.blockingDiagnostics().map(\.message)
        #expect(messages.contains { $0.contains("Unknown runner") })
        #expect(messages.contains { $0.contains("Unknown mode") })
    }

    @Test func warningsRemainNonBlockingButRootPrivilegeErrorsBlock() {
        let warningOnly = ConfigLoad(
            config: HearthConfig(controlEnabled: true, controlToken: "short"),
            note: nil,
            isProblem: false,
            createdDefault: false)
        #expect(warningOnly.blockingDiagnostics().isEmpty)
        #expect(!warningOnly.blockingDiagnostics(runningAsRoot: true).isEmpty)
    }
}
