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

    /// Drive a fresh machine to the failing wait state (the third failure trips
    /// it) and return it plus the current instant.
    private func driveToFailing() -> (SupervisorMachine, Date) {
        var machine = SupervisorMachine(config: config())
        var t = Date(timeIntervalSince1970: 0)
        _ = machine.start(now: t)
        for index in 0..<3 {
            _ = machine.observe(dead(), now: t)
            if index < 2 {   // first two are normal .down backoff; respawn for the next failure
                t = machine.scheduledRespawnAt
                _ = machine.respawnNow(now: t)
                t = t.addingTimeInterval(0.001)
            }
        }
        return (machine, t)
    }

    @Test func failingDoesNotReannounceAndKeepsSlowCadence() {
        var (machine, _) = driveToFailing()
        #expect(machine.phase == .failing)

        // The slow timer fires (restarting), the retry is probed and fails again:
        // re-enter failing with no second announcement and the same slow cadence.
        // This is what "stops thrashing" means.
        let scheduled = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: scheduled)
        #expect(machine.phase == .restarting)
        let out = machine.observe(dead(), now: scheduled.addingTimeInterval(0.001))
        #expect(machine.phase == .failing)
        #expect(out.nextWait == 30)
        #expect(!out.enteredFailing)
    }

    @Test func respawnWhileFailingProbesAsRestarting() {
        var (machine, _) = driveToFailing()
        #expect(machine.phase == .failing)

        // The slow timer fires: respawn moves to restarting so the engine actually
        // probes the fresh child. The bug was staying in failing, where the engine
        // never probes, so a crash loop could never recover. The failing context
        // survives in failingSince.
        let scheduled = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: scheduled)
        #expect(machine.phase == .restarting)
        #expect(machine.failingSince != nil)
    }

    @Test func recoveryFromFailingResetsEverything() {
        var (machine, _) = driveToFailing()
        #expect(machine.phase == .failing)

        // The slow timer fires; the fresh child is probed (restarting) and comes
        // back healthy. Because it had been failing this session, the all-clear is
        // a recovery, and every failure counter resets.
        let scheduled = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: scheduled)
        #expect(machine.phase == .restarting)
        let out = machine.observe(HealthReport(isAlive: true, readiness: .ready), now: scheduled.addingTimeInterval(1))

        #expect(machine.phase == .healthy)
        #expect(out.emittedEvents.contains(.recovered))
        #expect(machine.consecutiveFailures == 0)
        #expect(machine.failingSince == nil)
    }

    @Test func failuresAgingOutOfTheWindowClearFailingSince() {
        var (machine, _) = driveToFailing()
        #expect(machine.phase == .failing)
        #expect(machine.failingSince != nil)

        // The slow timer fires; the retry is probed and fails again, but far
        // enough later that every earlier failure has aged out of the 600s crash
        // loop window. The machine drops back to normal .down backoff, and the
        // failing marker must clear with the phase.
        let scheduled = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: scheduled)
        _ = machine.observe(dead(), now: scheduled.addingTimeInterval(700))
        #expect(machine.phase == .down)
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
