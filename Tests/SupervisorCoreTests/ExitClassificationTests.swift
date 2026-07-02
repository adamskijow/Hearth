// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

/// RunnerHeuristics.classify decides what the user is told about why the runner
/// died. These pin the two rules the notifications depend on: stderr signatures
/// only count for an abnormal end, and a signaled exit with no recorded signal
/// number is an unknown, not a phantom signal.
struct ExitClassificationTests {
    @Test func cleanExitIsNeverOutOfMemory() {
        // A runner that logged a transient allocation complaint and then was
        // stopped cleanly must not be reported as an out-of-memory kill.
        let exit = ProcessExit(code: 0)
        #expect(RunnerHeuristics.classify(exit, stderr: ["ggml: failed to allocate buffer"]) == .cleanExit)
    }

    @Test func abnormalExitWithSignatureIsOutOfMemory() {
        let killed = ProcessExit(code: 0, wasSignaled: true, signal: 9)
        #expect(RunnerHeuristics.classify(killed, stderr: ["out of memory"]) == .outOfMemory)
        let crashed = ProcessExit(code: 1)
        #expect(RunnerHeuristics.classify(crashed, stderr: ["cannot allocate"]) == .outOfMemory)
    }

    @Test func signaledWithoutANumberIsUnknown() {
        // The shape status() reports when waitpid failed because the child was
        // already reaped elsewhere: dead, cause unknown, no invented SIGKILL.
        let lost = ProcessExit(code: 0, wasSignaled: true, signal: nil)
        #expect(RunnerHeuristics.classify(lost, stderr: []) == .unknown)
    }

    @Test func plainOutcomesClassifyDirectly() {
        #expect(RunnerHeuristics.classify(nil, stderr: []) == .running)
        #expect(RunnerHeuristics.classify(ProcessExit(code: 0), stderr: []) == .cleanExit)
        #expect(RunnerHeuristics.classify(ProcessExit(code: 3), stderr: []) == .crash(code: 3))
        #expect(RunnerHeuristics.classify(ProcessExit(code: 0, wasSignaled: true, signal: 15), stderr: []) == .signal(15))
    }
}
