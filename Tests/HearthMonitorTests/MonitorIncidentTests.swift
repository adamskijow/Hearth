// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import HearthMonitorCore

@Suite("Monitor incident history")
struct MonitorIncidentTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    @Test("Only confirmed down opens an incident, and recovery closes it")
    func lifecycle() throws {
        let target = MonitorTarget(failureThreshold: 2)
        var ledger = MonitorIncidentLedger()
        var snapshot = MonitorSnapshot(targetID: target.id, now: start)
        snapshot = MonitorStateReducer.failure(snapshot, reason: .timedOut, threshold: 2, at: start)
        #expect(ledger.observe(target: target, snapshot: snapshot) == .none)

        snapshot = MonitorStateReducer.failure(
            snapshot, reason: .inferenceTimedOut, threshold: 2,
            at: start.addingTimeInterval(10))
        let opened = ledger.observe(target: target, snapshot: snapshot)
        let id = try #require(opened.incidentID)
        #expect(ledger.incidents.count == 1)
        #expect(ledger.incident(id: id)?.inferenceLevel == true)

        var busyUnverified = snapshot
        busyUnverified.phase = .busy
        #expect(!busyUnverified.isServing)
        #expect(ledger.observe(target: target, snapshot: busyUnverified) == .none)
        #expect(ledger.incident(id: id)?.endedAt == nil)

        snapshot = MonitorStateReducer.success(
            snapshot, phase: .healthy,
            at: start.addingTimeInterval(40))
        #expect(ledger.observe(target: target, snapshot: snapshot) == .recovered(id))
        #expect(ledger.incident(id: id)?.duration == 30)
        #expect(ledger.incident(id: id)?.resolution == .recovered)
    }

    @Test("Relaunch-style recovery closes an existing open incident")
    func closesWithoutPriorRuntimeState() throws {
        let target = MonitorTarget()
        let incident = MonitorIncident(
            targetID: target.id,
            targetName: target.name,
            startedAt: start,
            lastObservedAt: start,
            cause: "Down",
            inferenceLevel: false)
        var ledger = MonitorIncidentLedger(incidents: [incident])
        var fresh = MonitorSnapshot(targetID: target.id, now: start.addingTimeInterval(20))
        fresh = MonitorStateReducer.success(
            fresh, phase: .healthy,
            at: start.addingTimeInterval(20))
        #expect(ledger.observe(target: target, snapshot: fresh) == .recovered(incident.id))
    }

    @Test("Removing a down target records monitoring stopped, not recovered")
    func stopMonitoring() throws {
        let target = MonitorTarget()
        let incident = MonitorIncident(
            targetID: target.id,
            targetName: target.name,
            startedAt: start,
            lastObservedAt: start,
            cause: "Down",
            inferenceLevel: false)
        var ledger = MonitorIncidentLedger(incidents: [incident])
        #expect(ledger.stopMonitoring(targetID: target.id, at: start.addingTimeInterval(5))
                == .monitoringStopped(incident.id))
        #expect(ledger.incident(id: incident.id)?.resolution == .monitoringStopped)
    }

    @Test("Alert markers survive coding and prevent duplicate marks")
    func alertMarkers() throws {
        let target = MonitorTarget()
        let incident = MonitorIncident(
            targetID: target.id,
            targetName: target.name,
            startedAt: start,
            lastObservedAt: start,
            cause: "Down",
            inferenceLevel: false)
        var ledger = MonitorIncidentLedger(incidents: [incident])
        let firstMark = ledger.markOutageAlerted(id: incident.id, at: start)
        let duplicateMark = ledger.markOutageAlerted(id: incident.id, at: start)
        #expect(firstMark)
        #expect(!duplicateMark)
        let decoded = try JSONDecoder().decode(
            MonitorIncidentLedger.self,
            from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }

    @Test("The bounded ledger retains open incidents")
    func bounded() {
        let target = MonitorTarget()
        var incidents = (0..<15).map { offset in
            MonitorIncident(
                targetID: UUID(),
                targetName: "Old \(offset)",
                startedAt: start.addingTimeInterval(Double(offset)),
                lastObservedAt: start,
                endedAt: start,
                resolution: .recovered,
                cause: "Down",
                inferenceLevel: false)
        }
        incidents.append(MonitorIncident(
            targetID: target.id,
            targetName: target.name,
            startedAt: start.addingTimeInterval(-1),
            lastObservedAt: start,
            cause: "Still down",
            inferenceLevel: false))
        let ledger = MonitorIncidentLedger(incidents: incidents, limit: 10)
        #expect(ledger.incidents.count == 10)
        #expect(ledger.openIncident(targetID: target.id) != nil)
    }
}
