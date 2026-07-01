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

    // MARK: - the deferred group SIGKILL guard

    @Test func deferredKillIsSkippedOnceTheLeaderWasReaped() {
        // After the reap the pid, which is also the group id, is free for reuse:
        // a blind killpg could SIGKILL an unrelated recycled group.
        let spawn = identity(pid: 4242, start: 1_700_000_000)
        #expect(!RunnerSweep.deferredKillAllowed(leaderReaped: true, spawn: spawn, live: spawn))
    }

    @Test func deferredKillProceedsForAnUnreapedLiveLeader() {
        let spawn = identity(pid: 4242, start: 1_700_000_000)
        #expect(RunnerSweep.deferredKillAllowed(leaderReaped: false, spawn: spawn, live: spawn))
    }

    @Test func deferredKillIsSkippedWhenTheProbeSeesADifferentInstance() {
        // Same pid, different start time: not the child we spawned.
        let spawn = identity(pid: 4242, start: 1_700_000_000)
        let live = identity(pid: 4242, start: 1_700_009_999)
        #expect(!RunnerSweep.deferredKillAllowed(leaderReaped: false, spawn: spawn, live: live))
    }

    @Test func deferredKillProceedsForAnUnreapedZombieLeader() {
        // A dead-but-unreaped leader reports no live identity, but its pid, and
        // with it the group id, stays reserved until the supervisor reaps it, so
        // the group SIGKILL still lands on wedged members and nothing else.
        let spawn = identity(pid: 4242, start: 1_700_000_000)
        #expect(RunnerSweep.deferredKillAllowed(leaderReaped: false, spawn: spawn, live: nil))
    }
}
