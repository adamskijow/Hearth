// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The bounded restart category (for the hearth_last_restart metric and the
/// /status lastRestartCategory field): every restart path stamps a low-cardinality
/// category, deliberate restarts included.
struct RestartCategoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func healthyMachine() -> SupervisorMachine {
        var m = SupervisorMachine(config: RestartPolicyConfig(startupGrace: 0))
        _ = m.start(now: t0)
        _ = m.observe(HealthReport(isAlive: true, readiness: .ready), now: t0)
        return m
    }

    @Test func freshMachineHasNoCategoryYet() {
        #expect(healthyMachine().lastRestartCategory == nil)
    }

    @Test func deliberateRestartsCarryTheirCategory() {
        var manual = healthyMachine(); _ = manual.userRestart(now: t0)
        #expect(manual.lastRestartCategory == "manual")

        var maint = healthyMachine(); _ = maint.maintenanceRestart(now: t0)
        #expect(maint.lastRestartCategory == "maintenance")

        // The engine passes "binary-upgrade" when an on-disk binary change drove
        // the restart, distinguishing it from a scheduled maintenance cycle.
        var upgrade = healthyMachine(); _ = upgrade.maintenanceRestart(now: t0, category: "binary-upgrade")
        #expect(upgrade.lastRestartCategory == "binary-upgrade")

        var mem = healthyMachine(); _ = mem.memoryLimitRestart(residentBytes: 9, limitBytes: 8, now: t0)
        #expect(mem.lastRestartCategory == "memory-limit")
    }

    @Test func aFailureRestartMirrorsTheDownCategory() {
        var m = healthyMachine()
        // A wedge: alive but not answering, which classifies as "wedged".
        _ = m.observe(HealthReport(isAlive: true, readiness: .timedOut), now: t0.addingTimeInterval(1))
        #expect(m.lastRestartCategory == "wedged")
        #expect(m.lastRestartCategory == m.lastDownCategory)
    }
}
