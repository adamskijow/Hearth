// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct RunnerSweepTests {
    private func identity(pid: Int32, start: UInt64) -> RunnerProcessIdentity {
        RunnerProcessIdentity(pid: pid, pgid: pid, startTimeSeconds: start, executablePath: "/opt/homebrew/bin/ollama")
    }

    @Test func sweepsTheSameLiveProcess() {
        let recorded = identity(pid: 4242, start: 1_700_000_000)
        let live = identity(pid: 4242, start: 1_700_000_000)
        #expect(RunnerSweep.shouldSweep(recorded: recorded, live: live))
    }

    @Test func doesNotSweepARecycledPID() {
        // Same PID, different start time: a different process reused the number.
        let recorded = identity(pid: 4242, start: 1_700_000_000)
        let live = identity(pid: 4242, start: 1_700_009_999)
        #expect(!RunnerSweep.shouldSweep(recorded: recorded, live: live))
    }

    @Test func doesNotSweepADeadPID() {
        let recorded = identity(pid: 4242, start: 1_700_000_000)
        #expect(!RunnerSweep.shouldSweep(recorded: recorded, live: nil))
    }

    @Test func identityRoundTripsThroughJSON() throws {
        let original = identity(pid: 99, start: 12345)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunnerProcessIdentity.self, from: data)
        #expect(decoded == original)
    }
}
