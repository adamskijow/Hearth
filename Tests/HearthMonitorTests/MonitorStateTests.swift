// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import HearthMonitorCore

@Suite("Monitor state")
struct MonitorStateTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("A transient miss is confirmed before declaring an outage")
    func failureHysteresis() {
        let initial = MonitorSnapshot(targetID: UUID(), now: start)
        let healthy = MonitorStateReducer.success(initial, phase: .healthy, at: start)
        let first = MonitorStateReducer.failure(
            healthy, reason: .unreachable, threshold: 2, at: start.addingTimeInterval(10))
        #expect(first.phase == .checking)
        #expect(first.isConfirmingFailure)
        #expect(first.consecutiveFailures == 1)

        let second = MonitorStateReducer.failure(
            first, reason: .unreachable, threshold: 2, at: start.addingTimeInterval(20))
        #expect(second.phase == .down)
        #expect(second.healthySince == nil)
    }

    @Test("One successful check recovers immediately")
    func immediateRecovery() {
        let initial = MonitorSnapshot(targetID: UUID(), now: start)
        let first = MonitorStateReducer.failure(
            initial, reason: .timedOut, threshold: 1, at: start)
        let recoveredAt = start.addingTimeInterval(5)
        let recovered = MonitorStateReducer.success(first, phase: .healthy, at: recoveredAt)
        #expect(recovered.phase == .healthy)
        #expect(recovered.consecutiveFailures == 0)
        #expect(recovered.failure == nil)
        #expect(recovered.healthySince == recoveredAt)
    }

    @Test("A transient miss does not reset healthy duration")
    func transientMissKeepsHealthySince() {
        let initial = MonitorSnapshot(targetID: UUID(), now: start)
        let healthy = MonitorStateReducer.success(initial, phase: .healthy, at: start)
        let missed = MonitorStateReducer.failure(
            healthy, reason: .unreachable, threshold: 2,
            at: start.addingTimeInterval(10))
        let recovered = MonitorStateReducer.success(
            missed, phase: .healthy, at: start.addingTimeInterval(20))
        #expect(recovered.healthySince == start)
    }

    @Test("Busy is a serving state")
    func busyServes() {
        let initial = MonitorSnapshot(targetID: UUID(), now: start)
        let busy = MonitorStateReducer.success(initial, phase: .busy, at: start)
        #expect(busy.isServing)
        #expect(busy.phase == .busy)
    }
}
