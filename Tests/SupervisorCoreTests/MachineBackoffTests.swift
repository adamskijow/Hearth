// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Exponential backoff timing, capped, with crash loop detection held off by a
/// high threshold so we observe backoff in isolation.
struct MachineBackoffTests {
    @Test func backoffGrowsExponentiallyAndCapsAtMax() {
        let config = RestartPolicyConfig(
            startupGrace: 0,
            initialBackoff: 1,
            backoffMultiplier: 2,
            maxBackoff: 10,
            crashLoopThreshold: 100,   // never trips here
            crashLoopWindow: 100_000
        )
        var machine = SupervisorMachine(config: config)
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)

        var observedBackoffs: [TimeInterval] = []
        for _ in 0..<6 {
            let dead = HealthReport(isAlive: false, readiness: .unknown, exitReason: .crash(code: 1))
            let out = machine.observe(dead, now: t)
            observedBackoffs.append(out.nextWait)
            #expect(machine.phase == .down)

            // Jump to the scheduled respawn and spawn again, then nudge forward so
            // the next failure is observed at a fresh instant.
            t = machine.scheduledRespawnAt
            _ = machine.respawnNow(now: t)
            t = t.addingTimeInterval(0.001)
        }

        // 1, 2, 4, 8, then capped at 10.
        #expect(observedBackoffs == [1, 2, 4, 8, 10, 10])
    }

    @Test func backoffResetsAfterRecovery() {
        let config = RestartPolicyConfig(
            startupGrace: 0,
            initialBackoff: 1,
            backoffMultiplier: 2,
            maxBackoff: 60,
            crashLoopThreshold: 100,
            crashLoopWindow: 100_000
        )
        var machine = SupervisorMachine(config: config)
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)

        // Two failures: consecutive failure count should reach 2.
        for _ in 0..<2 {
            _ = machine.observe(
                HealthReport(isAlive: false, readiness: .unknown, exitReason: .crash(code: 1)),
                now: t
            )
            t = machine.scheduledRespawnAt
            _ = machine.respawnNow(now: t)
        }
        #expect(machine.consecutiveFailures == 2)

        // Recover.
        _ = machine.observe(HealthReport(isAlive: true, readiness: .ready), now: t.addingTimeInterval(1))
        #expect(machine.consecutiveFailures == 0)

        // Next failure starts the backoff from the beginning.
        t = t.addingTimeInterval(2)
        let out = machine.observe(
            HealthReport(isAlive: false, readiness: .unknown, exitReason: .crash(code: 1)),
            now: t
        )
        #expect(out.nextWait == 1)
    }
}
