// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The liveness versus readiness distinction, startup grace, and the
/// becameHealthy versus recovered transitions, all on the pure machine.
struct MachineHealthTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func ready() -> HealthReport {
        HealthReport(isAlive: true, readiness: .ready)
    }

    private func dead(_ reason: ExitReason = .crash(code: 1)) -> HealthReport {
        HealthReport(isAlive: false, readiness: .unknown, exitReason: reason)
    }

    @Test func failingStreakDistinguishesAWedgeFromAProcessExit() {
        // The signal the opt-in reboot policy keys on: a pure "alive but not
        // answering" wedge (which a runner can fake over HTTP) is not a process
        // exit; an actual crash is; and returning to healthy clears the streak.
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 30))
        _ = machine.start(now: t0)
        _ = machine.observe(ready(), now: t0.addingTimeInterval(2))
        #expect(!machine.failingStreakHadProcessExit)

        // A wedge alone does not count as a process exit.
        _ = machine.observe(HealthReport(isAlive: true, readiness: .timedOut), now: t0.addingTimeInterval(40))
        #expect(!machine.failingStreakHadProcessExit)

        // A real crash does.
        _ = machine.respawnNow(now: t0.addingTimeInterval(42))
        _ = machine.observe(dead(), now: t0.addingTimeInterval(44))
        #expect(machine.failingStreakHadProcessExit)

        // Recovering to healthy resets the streak.
        _ = machine.respawnNow(now: t0.addingTimeInterval(46))
        _ = machine.observe(ready(), now: t0.addingTimeInterval(48))
        #expect(machine.phase == .healthy)
        #expect(!machine.failingStreakHadProcessExit)
    }

    @Test func manualRestartOfAHealthyRunnerComesBackQuiet() {
        // Restarting a healthy runner (a routine model or config change) is not
        // a recovery: nothing failed, so no all-clear push.
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 30))
        _ = machine.start(now: t0)
        _ = machine.observe(ready(), now: t0.addingTimeInterval(2))
        #expect(machine.phase == .healthy)

        _ = machine.userRestart(now: t0.addingTimeInterval(10))
        let out = machine.observe(ready(), now: t0.addingTimeInterval(12))
        #expect(out.emittedEvents.contains(.becameHealthy))
        #expect(!out.emittedEvents.contains(.recovered))
    }

    @Test func manualRestartOfADownRunnerStillAnnouncesRecovery() {
        // The user got a down alert and restarted by hand; coming back healthy
        // is the all-clear they are waiting for.
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 30))
        _ = machine.start(now: t0)
        _ = machine.observe(ready(), now: t0.addingTimeInterval(2))
        _ = machine.observe(dead(), now: t0.addingTimeInterval(4))
        #expect(machine.phase == .down)

        _ = machine.userRestart(now: t0.addingTimeInterval(6))
        let out = machine.observe(ready(), now: t0.addingTimeInterval(8))
        #expect(out.emittedEvents.contains(.recovered))
    }

    @Test func aBusyReportIsServingNotAFailure() {
        // 503 means the queue is full and the runner is working; treating it as
        // a failure would restart a healthy server under load.
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 30))
        _ = machine.start(now: t0)
        _ = machine.observe(ready(), now: t0.addingTimeInterval(2))
        #expect(machine.phase == .healthy)

        let out = machine.observe(HealthReport(isAlive: true, readiness: .busy), now: t0.addingTimeInterval(40))
        #expect(machine.phase == .healthy)
        #expect(machine.consecutiveFailures == 0)
        #expect(!out.effects.contains(.kill))
    }

    @Test func readinessCatchesHungButAliveRunner() {
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 30))
        _ = machine.start(now: t0)
        _ = machine.observe(ready(), now: t0.addingTimeInterval(2))
        #expect(machine.phase == .healthy)

        // The PID is alive, but readiness times out. A plain liveness check would
        // call this healthy; readiness flags it down.
        let hung = HealthReport(isAlive: true, readiness: .timedOut)
        let out = machine.observe(hung, now: t0.addingTimeInterval(40))

        #expect(machine.phase == .down)
        #expect(out.emittedEvents.contains(.down(.wedged)))
        // A wedged but live process must be killed before it can be respawned.
        #expect(out.effects.contains(.kill))
    }

    @Test func aliveButNotReadyWithinStartupGraceStaysStarting() {
        var machine = SupervisorMachine(
            config: RestartPolicyConfig(startupGrace: 30, startupProbeInterval: 1)
        )
        _ = machine.start(now: t0)

        // Five seconds in, still warming up. Not a failure.
        let warming = HealthReport(isAlive: true, readiness: .notReady)
        let out = machine.observe(warming, now: t0.addingTimeInterval(5))

        #expect(machine.phase == .starting)
        #expect(out.nextWait == 1)
        #expect(out.emittedEvents.isEmpty)
        #expect(machine.consecutiveFailures == 0)
    }

    @Test func aliveButNotReadyPastStartupGraceIsAFailure() {
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 30))
        _ = machine.start(now: t0)

        let warming = HealthReport(isAlive: true, readiness: .notReady)
        let out = machine.observe(warming, now: t0.addingTimeInterval(31))

        #expect(machine.phase == .down)
        #expect(out.emittedEvents.contains(.down(.wedged)))
    }

    @Test func firstHealthyEmitsBecameHealthyNotRecovered() {
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 30))
        _ = machine.start(now: t0)
        let out = machine.observe(ready(), now: t0.addingTimeInterval(1))

        #expect(machine.phase == .healthy)
        #expect(out.emittedEvents.contains(.becameHealthy))
        #expect(!out.emittedEvents.contains(.recovered))
        #expect(machine.healthySince != nil)
    }

    @Test func returnToHealthyAfterFailureEmitsRecovered() {
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 0))
        var t = t0
        _ = machine.start(now: t)
        _ = machine.observe(ready(), now: t.addingTimeInterval(1))
        #expect(machine.phase == .healthy)

        // Crash.
        t = t0.addingTimeInterval(2)
        _ = machine.observe(dead(), now: t)
        #expect(machine.phase == .down)

        // Backoff elapses, respawn, then it comes back ready.
        t = machine.scheduledRespawnAt
        _ = machine.respawnNow(now: t)
        let out = machine.observe(ready(), now: t.addingTimeInterval(1))

        #expect(machine.phase == .healthy)
        #expect(out.emittedEvents.contains(.recovered))
        #expect(!out.emittedEvents.contains(.becameHealthy))
        #expect(machine.consecutiveFailures == 0)
    }

    @Test func cleanExitIsStillRestarted() {
        // In managed mode the supervisor keeps the runner alive even after a
        // clean stop; the reason is recorded but recovery proceeds.
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 0))
        _ = machine.start(now: t0)
        _ = machine.observe(ready(), now: t0.addingTimeInterval(1))

        let out = machine.observe(dead(.cleanExit), now: t0.addingTimeInterval(2))
        #expect(machine.phase == .down)
        #expect(out.emittedEvents.contains(.down(.crashed(.cleanExit))))
    }
}
