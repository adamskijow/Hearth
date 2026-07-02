// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The daily maintenance window: parsing, midnight wrap, and how it gates a due
/// maintenance restart. Pure wall-clock logic; the engine supplies the minute.
struct MaintenanceWindowTests {
    @Test func parsesAPlainWindow() throws {
        let window = try #require(MaintenanceWindow.parse("03:00-06:30"))
        #expect(window.startMinute == 3 * 60)
        #expect(window.endMinute == 6 * 60 + 30)
        #expect(window.contains(minuteOfDay: 4 * 60))
        #expect(!window.contains(minuteOfDay: 7 * 60))
        #expect(window.contains(minuteOfDay: 3 * 60))      // start is inclusive
        #expect(!window.contains(minuteOfDay: 6 * 60 + 30)) // end is exclusive
    }

    @Test func aWindowSpanningMidnightWraps() throws {
        let window = try #require(MaintenanceWindow.parse("23:00-06:00"))
        #expect(window.contains(minuteOfDay: 23 * 60 + 30))
        #expect(window.contains(minuteOfDay: 2 * 60))
        #expect(!window.contains(minuteOfDay: 12 * 60))
    }

    @Test func rejectsMalformedWindows() {
        for raw in ["", "3-6", "03:00", "03:00-24:00", "03:60-06:00", "banana", "03:00-03:00"] {
            #expect(MaintenanceWindow.parse(raw) == nil, "\(raw) should not parse")
        }
    }

    @Test func aDueRestartWaitsForTheWindow() {
        let policy = RestartPolicyConfig(
            maintenanceRestartInterval: 3600,
            maintenanceWindow: MaintenanceWindow.parse("03:00-06:00")
        )
        let healthySince = Date(timeIntervalSince1970: 0)
        let now = healthySince.addingTimeInterval(7200)   // interval is due

        #expect(policy.maintenanceRestartDue(healthySince: healthySince, now: now, minuteOfDay: 4 * 60))
        #expect(!policy.maintenanceRestartDue(healthySince: healthySince, now: now, minuteOfDay: 14 * 60))
        // No window configured: any time is fine.
        let anytime = RestartPolicyConfig(maintenanceRestartInterval: 3600)
        #expect(anytime.maintenanceRestartDue(healthySince: healthySince, now: now, minuteOfDay: 14 * 60))
    }

    @Test func configMapsTheWindowIntoThePolicy() {
        let config = HearthConfig(maintenanceRestartHours: 24, maintenanceWindow: "02:00-05:00")
        #expect(config.policy().maintenanceWindow == MaintenanceWindow.parse("02:00-05:00"))
        // An unparseable window degrades to nil (doctor warns separately).
        let broken = HearthConfig(maintenanceRestartHours: 24, maintenanceWindow: "whenever")
        #expect(broken.policy().maintenanceWindow == nil)
    }

    @Test func diagnosticsFlagBadWindowAndHeartbeat() {
        let badWindow = HearthConfig(maintenanceWindow: "whenever")
        #expect(ConfigDiagnostics.check(badWindow).contains {
            $0.severity == .warning && $0.message.contains("maintenanceWindow")
        })
        let badHeartbeat = HearthConfig(heartbeatURL: "not a url")
        #expect(ConfigDiagnostics.check(badHeartbeat).contains {
            $0.severity == .warning && $0.message.contains("heartbeatURL")
        })
        let fine = HearthConfig(maintenanceWindow: "03:00-06:00",
                                heartbeatURL: "https://hc-ping.com/abc")
        #expect(!ConfigDiagnostics.check(fine).contains {
            $0.message.contains("maintenanceWindow") || $0.message.contains("heartbeatURL")
        })
    }
}
