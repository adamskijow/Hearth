// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import Testing
@testable import HearthMonitor

@Suite("Monitor alert wording")
struct MonitorAlertContentTests {
    @Test("Inference alerts explain the attached-only limitation")
    func inferenceAlert() {
        let incident = MonitorIncident(
            targetID: UUID(), targetName: "GPU Mac",
            startedAt: Date(), lastObservedAt: Date(),
            cause: "The API answered, but inference timed out.",
            inferenceLevel: true)
        let message = MonitorAlertContent.outage(incident)
        #expect(message.title.contains("inference is wedged"))
        #expect(message.body.contains("cannot restart"))
    }

    @Test("Recovery alert includes incident duration")
    func recoveryAlert() {
        let start = Date(timeIntervalSince1970: 1_000)
        let incident = MonitorIncident(
            targetID: UUID(), targetName: "GPU Mac",
            startedAt: start, lastObservedAt: start.addingTimeInterval(65),
            endedAt: start.addingTimeInterval(65), resolution: .recovered,
            cause: "Down", inferenceLevel: false,
            outageAlertedAt: start)
        let message = MonitorAlertContent.recovery(incident)
        #expect(message.title == "GPU Mac recovered")
        #expect(message.body.contains("1m"))
    }

    @Test("Apple alerts state the system-service recovery boundary")
    func appleAlert() {
        let incident = MonitorIncident(
            targetID: AppleModelHealthSnapshot.incidentTargetID,
            targetName: "Apple Intelligence",
            startedAt: Date(),
            lastObservedAt: Date(),
            cause: "Two functional checks timed out.",
            inferenceLevel: true)
        let outage = MonitorAlertContent.outage(incident)
        #expect(outage.title == "Apple Intelligence health check failed")
        #expect(outage.body.contains("cannot restart Apple's system model service"))
    }
}
