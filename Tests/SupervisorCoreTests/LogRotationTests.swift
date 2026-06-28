// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct LogRotationTests {
    @Test func shouldRotateAtOrAboveTheCap() {
        let policy = LogRotationPolicy(maxBytes: 100, keepFiles: 3)
        #expect(!policy.shouldRotate(currentBytes: 99))
        #expect(policy.shouldRotate(currentBytes: 100))
        #expect(policy.shouldRotate(currentBytes: 250))
    }

    @Test func zeroDisablesRotation() {
        #expect(!LogRotationPolicy(maxBytes: 0, keepFiles: 3).isEnabled)
        #expect(!LogRotationPolicy(maxBytes: 100, keepFiles: 0).isEnabled)
        #expect(!LogRotationPolicy(maxBytes: 0, keepFiles: 3).shouldRotate(currentBytes: 1_000_000))
        #expect(LogRotationPolicy(maxBytes: 0, keepFiles: 3).steps(forBase: "x.log").isEmpty)
    }

    @Test func stepsRotateOldestFirstWithoutClobbering() {
        let policy = LogRotationPolicy(maxBytes: 100, keepFiles: 3)
        #expect(policy.steps(forBase: "runner.log") == [
            .delete("runner.log.3"),
            .move(from: "runner.log.2", to: "runner.log.3"),
            .move(from: "runner.log.1", to: "runner.log.2"),
            .move(from: "runner.log", to: "runner.log.1")
        ])
    }

    @Test func keepOneRotatedFile() {
        let policy = LogRotationPolicy(maxBytes: 100, keepFiles: 1)
        #expect(policy.steps(forBase: "runner.log") == [
            .delete("runner.log.1"),
            .move(from: "runner.log", to: "runner.log.1")
        ])
    }

    @Test func configMapsToPolicyWithDefaults() {
        let defaults = HearthConfig()
        #expect(defaults.logRotationPolicy() == LogRotationPolicy(maxBytes: 5_000_000, keepFiles: 3))
        let custom = HearthConfig(logMaxBytes: 1_000, logKeepFiles: 5)
        #expect(custom.logRotationPolicy() == LogRotationPolicy(maxBytes: 1_000, keepFiles: 5))
    }
}
