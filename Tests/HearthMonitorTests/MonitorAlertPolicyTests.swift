// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import HearthMonitorCore

@Suite("Monitor alert policy")
struct MonitorAlertPolicyTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test("Snooze suppresses but does not consume an open outage")
    func snoozedOutageBecomesPending() {
        let targetID = UUID()
        let incident = MonitorIncident(
            targetID: targetID, targetName: "GPU",
            startedAt: now, lastObservedAt: now,
            cause: "Down", inferenceLevel: false)
        let ledger = MonitorIncidentLedger(incidents: [incident])
        let snoozed = MonitorAlertPolicy.pendingOutages(
            in: ledger,
            monitoredTargetIDs: [targetID],
            alertsEnabled: true,
            snoozedUntil: now.addingTimeInterval(60),
            now: now)
        #expect(snoozed.isEmpty)
        let pending = MonitorAlertPolicy.pendingOutages(
            in: ledger,
            monitoredTargetIDs: [targetID],
            alertsEnabled: true,
            snoozedUntil: now,
            now: now)
        #expect(pending.map(\.id) == [incident.id])
    }

    @Test("Recovery only follows a delivered outage and expires quickly")
    func recoveryEligibility() {
        let incident = MonitorIncident(
            targetID: UUID(), targetName: "GPU",
            startedAt: now.addingTimeInterval(-120),
            lastObservedAt: now.addingTimeInterval(-30),
            endedAt: now.addingTimeInterval(-30),
            resolution: .recovered,
            cause: "Down", inferenceLevel: false,
            outageAlertedAt: now.addingTimeInterval(-100))
        let ledger = MonitorIncidentLedger(incidents: [incident])
        #expect(MonitorAlertPolicy.pendingRecoveries(
            in: ledger, alertsEnabled: true, snoozedUntil: nil, now: now).map(\.id) == [incident.id])
        #expect(MonitorAlertPolicy.pendingRecoveries(
            in: ledger, alertsEnabled: true, snoozedUntil: nil,
            now: now.addingTimeInterval(400)).isEmpty)
    }

    @Test("Tomorrow morning is stable across a daylight-saving calendar")
    func tomorrowMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let afterMorning = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 10)))
        let result = MonitorSnoozeSchedule.tomorrowMorning(from: afterMorning, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: result)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 9)
        #expect(components.hour == 8)
    }
}
