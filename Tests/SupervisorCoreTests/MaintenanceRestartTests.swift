// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct MaintenanceRestartTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func dueOnlyAfterTheIntervalOfHealthyUptime() {
        let policy = RestartPolicyConfig(maintenanceRestartInterval: 3600)
        #expect(!policy.maintenanceRestartDue(healthySince: nil, now: t0))                       // not healthy
        #expect(!policy.maintenanceRestartDue(healthySince: t0, now: t0.addingTimeInterval(3599)))
        #expect(policy.maintenanceRestartDue(healthySince: t0, now: t0.addingTimeInterval(3600)))
    }

    @Test func disabledIntervalNeverFires() {
        let off = RestartPolicyConfig(maintenanceRestartInterval: 0)
        #expect(!off.maintenanceRestartDue(healthySince: t0, now: t0.addingTimeInterval(1_000_000)))
    }

    @Test func machineCyclesAndComesBackQuietly() {
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 0))
        _ = machine.start(now: t0)
        _ = machine.observe(HealthReport(isAlive: true, readiness: .ready), now: t0)
        #expect(machine.phase == .healthy)

        let restart = machine.maintenanceRestart(now: t0.addingTimeInterval(86_400))
        #expect(machine.phase == .restarting)
        #expect(restart.emittedEvents.contains(.maintenanceRestart))
        #expect(restart.effects.contains(.spawn))
        #expect(machine.consecutiveFailures == 0)   // not counted as a failure
        #expect(machine.healthySince == nil)

        // Coming back from a maintenance restart is quiet (becameHealthy), not a
        // pushed recovery, so a daily cycle does not spam a Recovered alert.
        let back = machine.observe(HealthReport(isAlive: true, readiness: .ready), now: t0.addingTimeInterval(86_401))
        #expect(machine.phase == .healthy)
        #expect(back.emittedEvents.contains(.becameHealthy))
        #expect(!back.emittedEvents.contains(.recovered))
    }

    @Test func aRealRecoveryIsStillPushed() {
        // After a crash restart (not maintenance), the comeback is a recovery.
        var machine = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 0, initialBackoff: 1))
        _ = machine.start(now: t0)
        _ = machine.observe(HealthReport(isAlive: true, readiness: .ready), now: t0)
        _ = machine.observe(HealthReport(isAlive: false, readiness: .unknown, exitReason: .crash(code: 1)), now: t0.addingTimeInterval(1))
        _ = machine.respawnNow(now: machine.scheduledRespawnAt)
        let back = machine.observe(HealthReport(isAlive: true, readiness: .ready), now: machine.scheduledRespawnAt.addingTimeInterval(1))
        #expect(back.emittedEvents.contains(.recovered))
    }

    @Test func configMapsHoursAndFloorsTheInterval() {
        #expect(HearthConfig().policy().maintenanceRestartInterval == 0)              // off by default
        #expect(HearthConfig(maintenanceRestartHours: 24).policy().maintenanceRestartInterval == 86_400)
        // A tiny value is floored to one hour so it cannot loop.
        #expect(HearthConfig(maintenanceRestartHours: 0.001).policy().maintenanceRestartInterval == 3600)
    }
}
