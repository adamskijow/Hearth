// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Crash loop detection: N failures within window W trips the failing phase,
/// which stops fast thrashing, retries slowly, and recovers cleanly.
struct MachineCrashLoopTests {
    private func config() -> RestartPolicyConfig {
        RestartPolicyConfig(
            startupGrace: 0,
            initialBackoff: 1,
            backoffMultiplier: 2,
            maxBackoff: 60,
            crashLoopThreshold: 3,
            crashLoopWindow: 600,
            failingProbeInterval: 30
        )
    }

    private func dead() -> HealthReport {
        HealthReport(isAlive: false, readiness: .unknown, exitReason: .crash(code: 1))
    }

    @Test func threeRapidFailuresEnterFailingAndSlowDown() {
        var machine = SupervisorMachine(config: config())
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)

        // First two failures: normal fast backoff.
        var out = machine.observe(dead(), now: t)
        #expect(machine.phase == .down)
        #expect(out.nextWait == 1)
        t = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: t)
        t = t.addingTimeInterval(0.001)

        out = machine.observe(dead(), now: t)
        #expect(machine.phase == .down)
        #expect(out.nextWait == 2)
        t = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: t)
        t = t.addingTimeInterval(0.001)

        // Third failure trips the crash loop.
        out = machine.observe(dead(), now: t)
        #expect(machine.phase == .failing)
        // Slow cadence, not the fast backoff of 4 it would otherwise have been.
        #expect(out.nextWait == 30)
        #expect(out.enteredFailing)
        #expect(machine.failingSince != nil)
    }

    @Test func failingDoesNotReannounceAndKeepsSlowCadence() {
        var machine = SupervisorMachine(config: config())
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)

        // Drive to failing.
        for _ in 0..<3 {
            _ = machine.observe(dead(), now: t)
            t = machine.scheduledRespawnAt
            _ = machine.respawnNow(now: t)
            t = t.addingTimeInterval(0.001)
        }
        #expect(machine.phase == .failing)

        // Respawn slowly and fail again: still failing, no second announcement,
        // still the slow cadence. This is what "stops thrashing" means.
        let out = machine.observe(dead(), now: t)
        #expect(machine.phase == .failing)
        #expect(out.nextWait == 30)
        #expect(!out.enteredFailing)
    }

    @Test func respawnWhileFailingStaysFailing() {
        var machine = SupervisorMachine(config: config())
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)
        for _ in 0..<3 {
            _ = machine.observe(dead(), now: t)
            t = machine.scheduledRespawnAt
            _ = machine.respawnNow(now: t)
            t = t.addingTimeInterval(0.001)
        }
        #expect(machine.phase == .failing)

        // The slow timer fires: we respawn, but remain in the failing phase until
        // actually healthy again.
        t = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: t)
        #expect(machine.phase == .failing)
    }

    @Test func recoveryFromFailingResetsEverything() {
        var machine = SupervisorMachine(config: config())
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)
        for _ in 0..<3 {
            _ = machine.observe(dead(), now: t)
            t = machine.scheduledRespawnAt
            _ = machine.respawnNow(now: t)
            t = t.addingTimeInterval(0.001)
        }
        #expect(machine.phase == .failing)

        // Respawn and come back healthy.
        t = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: t)
        let out = machine.observe(HealthReport(isAlive: true, readiness: .ready), now: t.addingTimeInterval(1))

        #expect(machine.phase == .healthy)
        #expect(out.emittedEvents.contains(.recovered))
        #expect(machine.consecutiveFailures == 0)
        #expect(machine.failingSince == nil)
    }

    @Test func failuresOutsideWindowDoNotTrip() {
        // Threshold 3 within a 10 second window. Space failures 20 seconds apart
        // so the window never holds more than one.
        let cfg = RestartPolicyConfig(
            startupGrace: 0,
            initialBackoff: 1,
            backoffMultiplier: 1,   // flat backoff for predictable spacing
            maxBackoff: 1,
            crashLoopThreshold: 3,
            crashLoopWindow: 10,
            failingProbeInterval: 30
        )
        var machine = SupervisorMachine(config: cfg)
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)

        for _ in 0..<5 {
            _ = machine.observe(dead(), now: t)
            #expect(machine.phase == .down, "should never trip failing when failures are spread out")
            t = machine.scheduledRespawnAt
            _ = machine.respawnNow(now: t)
            t = t.addingTimeInterval(20)   // far outside the 10s window
        }
        #expect(machine.failingSince == nil)
    }
}
