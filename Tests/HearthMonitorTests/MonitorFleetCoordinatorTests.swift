// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import HearthMonitor
@testable import HearthMonitorCore

@MainActor
@Suite("Monitor fleet coordinator")
struct MonitorFleetCoordinatorTests {
    @Test("Multiple targets check independently and produce an overall state")
    func checksFleet() async {
        let first = MonitorTarget(name: "First", runner: "ollama")
        let second = MonitorTarget(name: "Second", runner: "mlx")
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        let fleet = MonitorFleetCoordinator(http: http, automaticallySchedules: false)
        fleet.apply([first, second])
        #expect(fleet.overallPhase == .checking)

        await fleet.checkNow(targetID: first.id)
        await fleet.checkNow(targetID: second.id)
        #expect(fleet.snapshots[first.id]?.phase == .healthy)
        #expect(fleet.snapshots[second.id]?.phase == .healthy)
        #expect(fleet.overallPhase == .healthy)
    }

    @Test("A display-name edit preserves live health")
    func nameEditPreservesState() async {
        var target = MonitorTarget(name: "Before")
        let fleet = MonitorFleetCoordinator(
            http: MonitorFakeHTTPClient(default: .ok(Data())),
            automaticallySchedules: false)
        fleet.apply([target])
        await fleet.checkNow(targetID: target.id)
        #expect(fleet.snapshots[target.id]?.phase == .healthy)

        target.name = "After"
        fleet.apply([target])
        #expect(fleet.snapshots[target.id]?.phase == .healthy)
        #expect(fleet.targets.first?.name == "After")
    }

    @Test("Removing a target drops its loop and snapshot")
    func removal() async {
        let target = MonitorTarget()
        var removed: UUID?
        let fleet = MonitorFleetCoordinator(
            http: MonitorFakeHTTPClient(default: .ok(Data())),
            automaticallySchedules: false)
        fleet.onTargetRemoved = { removed = $0 }
        fleet.apply([target])
        await fleet.checkNow(targetID: target.id)
        fleet.apply([])
        #expect(removed == target.id)
        #expect(fleet.snapshots[target.id] == nil)
        #expect(fleet.overallPhase == nil)
    }

    @Test("Check Now forces the configured inference probe")
    func manualCheckForcesDeepProbe() async throws {
        let target = MonitorTarget(
            probeModel: "tiny",
            deepProbeIntervalSeconds: 3600,
            failureThreshold: 1)
        let api = MonitorRunnerAPI(target: target)
        let request = try #require(api.deepReadinessRequest(model: "tiny"))
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        let fleet = MonitorFleetCoordinator(http: http, automaticallySchedules: false)
        fleet.apply([target])
        await fleet.checkNow(targetID: target.id, forceDeepProbe: false)
        #expect(http.postCount(request.url) == 1)

        http.set(request.url, outcome: .timedOut)
        await fleet.checkNow(targetID: target.id)
        #expect(http.postCount(request.url) == 2)
        #expect(fleet.snapshots[target.id]?.failure == .inferenceTimedOut)
    }
}
