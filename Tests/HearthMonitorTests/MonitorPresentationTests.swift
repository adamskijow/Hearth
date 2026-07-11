// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import HearthMonitor
@testable import HearthMonitorCore

@Suite("Monitor status presentation")
struct MonitorPresentationTests {
    @Test("Inference outage is named separately from API down")
    func inferenceTitle() {
        let target = MonitorTarget()
        var snapshot = MonitorSnapshot(targetID: target.id, now: Date())
        snapshot = MonitorStateReducer.failure(
            snapshot, reason: .inferenceTimedOut, threshold: 1, at: Date())
        #expect(MonitorPresentation.title(snapshot) == "Inference wedged")
        #expect(MonitorPresentation.detail(snapshot).contains("one-token inference"))
    }

    @Test("Busy after an inference failure says recovery is unverified")
    func busyRecoveryWording() {
        let target = MonitorTarget()
        var snapshot = MonitorSnapshot(targetID: target.id, now: Date())
        snapshot = MonitorStateReducer.failure(
            snapshot, reason: .inferenceTimedOut, threshold: 1, at: Date())
        snapshot.phase = .busy
        #expect(MonitorPresentation.title(snapshot) == "Busy (verifying recovery)")
        #expect(MonitorPresentation.detail(snapshot).contains("waiting to verify"))
    }

    @Test("Diagnostics are useful but do not include a response body")
    func diagnostics() {
        let target = MonitorTarget(name: "GPU")
        var snapshot = MonitorSnapshot(targetID: target.id, now: Date())
        snapshot = MonitorStateReducer.failure(
            snapshot, reason: .http(500), threshold: 1, at: Date())
        let report = MonitorDiagnosticsText.report(target: target, snapshot: snapshot)
        #expect(report.contains("State: Down"))
        #expect(report.contains("HTTP 500"))
        #expect(!report.lowercased().contains("response body"))
    }
}
