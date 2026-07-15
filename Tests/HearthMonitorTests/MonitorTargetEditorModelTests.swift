// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore
import Testing
@testable import HearthMonitor
@testable import HearthMonitorCore

@MainActor
@Suite("Monitor target editor model")
struct MonitorTargetEditorModelTests {
    @Test("Editing an endpoint invalidates its successful connection test")
    func endpointChangeNeedsRetest() async {
        let target = MonitorTarget()
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        let model = MonitorTargetEditorModel(target: target, http: http)

        model.testConnection()
        await model.waitForCurrentOperation()
        #expect(model.isConnectionVerified)
        model.host = "192.168.1.40"
        #expect(!model.isConnectionVerified)
        #expect(model.connectionRetestNeeded)
        #expect(model.needsSaveConfirmation)
    }

    @Test("A stale slow success cannot verify edited connection details")
    func staleSuccessIsIgnored() async {
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        http.setDelay(nanoseconds: 40_000_000)
        let model = MonitorTargetEditorModel(target: MonitorTarget(), http: http)

        model.testConnection()
        model.host = "10.0.0.9"
        await model.waitForCurrentOperation()
        #expect(!model.isConnectionVerified)
        #expect(model.feedback.contains("changed during the test"))
    }

    @Test("Starting a test clears a cancelled discovery spinner")
    func switchingOperationsClearsProgress() async {
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        http.setDelay(nanoseconds: 40_000_000)
        let model = MonitorTargetEditorModel(target: MonitorTarget(), http: http)

        model.discover()
        #expect(model.isDiscovering)
        model.testConnection()
        #expect(!model.isDiscovering)
        await model.waitForCurrentOperation()
        #expect(!model.isWorking)
    }

    @Test("Inference verification is tied to the exact selected model")
    func modelChangeNeedsRetest() async throws {
        let target = MonitorTarget(probeModel: "tiny")
        let request = try #require(
            MonitorRunnerAPI(target: target).deepReadinessRequest(model: "tiny"))
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        http.set(request.url, outcome: .ok(Data()))
        let model = MonitorTargetEditorModel(target: target, http: http)

        model.testInference()
        await model.waitForCurrentOperation()
        #expect(model.isInferenceVerified)
        #expect(model.isConnectionVerified)
        model.probeModel = "another"
        #expect(!model.isInferenceVerified)
        #expect(model.inferenceRetestNeeded)
    }

    @Test("Choosing another candidate clears a model from the old runner")
    func candidateClearsOldModel() {
        let model = MonitorTargetEditorModel(
            target: MonitorTarget(probeModel: "old-model"),
            http: MonitorFakeHTTPClient())
        model.useCandidate(DiscoveredRunner(kind: .mlx, host: "127.0.0.1", port: 8080))
        #expect(model.probeModel.isEmpty)
        #expect(model.deepProbeEnabled)
        #expect(model.validationIssues.contains(where: { $0.contains("model") }))
    }

    @Test("Bearer authentication requires a Keychain-bound credential")
    func bearerCredentialValidation() {
        let target = MonitorTarget(authentication: .bearer)
        let missing = MonitorTargetEditorModel(target: target, http: MonitorFakeHTTPClient())
        #expect(missing.validationIssues.contains(where: { $0.contains("bearer") }))

        let present = MonitorTargetEditorModel(
            target: target,
            bearerToken: "credential-value",
            http: MonitorFakeHTTPClient())
        #expect(!present.validationIssues.contains(where: { $0.contains("bearer") }))
        #expect(present.target.authentication == .bearer)
    }
}
