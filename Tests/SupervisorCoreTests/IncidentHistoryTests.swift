// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct IncidentHistoryTests {
    @Test func groupsFailureThroughRecovery() throws {
        let lines = [
            "2026-07-09 01:00:00  Became healthy",
            "2026-07-09 02:00:00  Down: stuck (still running, but not answering)",
            "2026-07-09 02:00:01  Restart scheduled (attempt 1, in 1s)",
            "2026-07-09 02:00:02  Restarted (attempt 1)",
            "2026-07-09 02:00:05  Recovered",
        ]
        let incident = try #require(IncidentHistory.build(lines).first)
        #expect(incident.reason == "stuck (still running, but not answering)")
        #expect(incident.events.count == 4)
        #expect(incident.recoveryTime == 5)
    }

    @Test func keepsAnUnresolvedIncidentVisible() throws {
        let lines = [
            "2026-07-09 02:00:00  Down: crashed (exit code 1)",
            "2026-07-09 02:00:02  Failing: 5 failures within 60s",
        ]
        let incident = try #require(IncidentHistory.build(lines).first)
        #expect(incident.recoveredAt == nil)
        #expect(incident.recoveryTime == nil)
    }

    @Test func aFreshHealthySessionClosesAPersistedIncident() throws {
        let lines = [
            "2026-07-09 02:00:00  Down: crashed (exit code 1)",
            "2026-07-09 02:01:00  Stopped",
            "2026-07-09 02:02:00  Started",
            "2026-07-09 02:02:03  Became healthy",
        ]
        let incident = try #require(IncidentHistory.build(lines).first)
        #expect(incident.recoveryTime == 123)
    }

    @Test func ignoresMalformedAndUnrelatedLines() {
        #expect(IncidentHistory.build(["garbage", "2026-07-09 01:00:00  Started"]).isEmpty)
    }
}
