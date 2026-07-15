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

    @Test("Runner failures provide a concrete next action")
    func runnerAction() {
        let target = MonitorTarget(name: "GPU", runner: "ollama", probeModel: "tiny")
        var snapshot = MonitorSnapshot(targetID: target.id, now: Date())
        snapshot = MonitorStateReducer.failure(
            snapshot, reason: .inferenceTimedOut, threshold: 1, at: Date())
        let action = MonitorActionGuidance.runner(target: target, snapshot: snapshot)
        #expect(action?.contains("restart Ollama") == true)
        #expect(action?.contains("fits available memory") == true)
    }

    @Test("Apple model failures name the system-owned recovery path")
    func appleAction() {
        var snapshot = AppleModelHealthSnapshot()
        snapshot.phase = .down
        snapshot.availability = .available
        snapshot.failure = .timedOut
        let action = MonitorActionGuidance.appleModel(snapshot)
        #expect(action?.contains("restart the Mac") == true)
        #expect(action?.contains("only macOS") == true)
    }
}
