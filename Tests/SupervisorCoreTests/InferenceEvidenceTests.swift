// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import SupervisorCore

private actor RestartOnDownNotifier: Notifier {
    private var callback: (@Sendable () async -> Void)?
    func setCallback(_ callback: @escaping @Sendable () async -> Void) { self.callback = callback }
    func notify(_ notification: HearthNotification) async {
        if case .down = notification.event, let callback {
            self.callback = nil
            await callback()
        }
    }
}

struct InferenceEvidenceTests {
    private struct Harness {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 1000))
        let processes = FakeProcessController()
        let http = FakeHTTPClient()
        let runner = OllamaRunner(binaryPath: "/fixture/ollama")
        let notifier = FakeNotifier()
        let engine: SupervisorEngine
        var url: URL { runner.deepReadinessRequest(model: "model")!.url }
        init(managed: Bool = true, observed: Bool = true) {
            engine = SupervisorEngine(clock: clock, processes: processes, http: http, runner: runner,
                power: FakePowerManager(), notifier: notifier, policy: RestartPolicyConfig(startupGrace: 0),
                managed: managed, deepProbe: DeepProbeConfig(model: "model", interval: 60, timeout: 30),
                inFlight: { 0 }, clientTrafficObserved: { observed })
            http.set(runner.readinessEndpoint, .ok(Data()))
            http.set(runner.modelsEndpoint, .ok(Data(#"{"models":[{"name":"model"}]}"#.utf8)))
        }
        func succeed() { http.set(url, .ok(Data(#"{"done":true,"eval_count":1}"#.utf8))) }
    }

    @Test(arguments: [5.0, 61.0])
    func deep503NeverUsesShallowBusyTimeout(interval: Double) async {
        let h = Harness(observed: false)
        h.http.set(h.url, .http(status: 503, body: Data()))
        await h.engine.start()
        for _ in stride(from: 0.0, through: 750.0, by: interval) {
            _ = await h.engine.stepOnce()
            h.clock.advance(by: interval)
        }
        let state = await h.engine.snapshot()
        #expect(h.processes.terminateCount == 0)
        #expect(state.api?.status == .responding)
        #expect(state.inference?.lastResult == .unchecked)
        #expect(state.inference?.deferredReason == .queueFull)
        #expect(state.busy == false)
    }

    @Test func attachedStopStartClearsSessionAndImmediatelyChecks() async {
        let h = Harness(managed: false)
        h.http.set(h.url, .timedOut)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        h.clock.advance(by: 61)
        _ = await h.engine.stepOnce()
        await h.engine.stop()
        await h.engine.start()
        #expect(await h.engine.snapshot().deepProbeLastFailedAt == nil)
        #expect(await h.engine.snapshot().inference?.lastCheckedAt == nil)
        _ = await h.engine.stepOnce()
        #expect(h.http.postCount(to: h.url) == 3)
        #expect(await h.engine.snapshot().isHealthy == false)
        h.succeed()
        await h.engine.restart()
        _ = await h.engine.stepOnce()
        #expect(h.http.postCount(to: h.url) == 4)
        #expect(await h.engine.snapshot().inference?.isVerified(asOf: h.clock.now) == true)
        #expect(h.processes.spawnCount == 0)
        #expect(h.processes.terminateCount == 0)
        #expect(await h.engine.snapshot().recovery?.withheldReason == .attached)
    }

    @Test func failureSurvivesReplacementAndUnloadedModelUntilValidatedSuccess() async {
        let h = Harness()
        h.succeed()
        await h.engine.start()
        _ = await h.engine.stepOnce()
        h.http.set(h.url, .timedOut)
        for _ in 0..<2 { h.clock.advance(by: 61); _ = await h.engine.stepOnce() }
        #expect(await h.engine.snapshot().phase == .down)
        h.clock.advance(by: 61)
        _ = await h.engine.stepOnce() // respawn
        _ = await h.engine.stepOnce() // replacement still fails
        #expect(await h.engine.snapshot().isHealthy == false)
        #expect(await h.notifier.received.filter { $0.event == .recovered }.isEmpty)
        h.http.set(h.runner.modelsEndpoint, .ok(Data(#"{"models":[]}"#.utf8)))
        h.clock.advance(by: 61)
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().inference?.deferredReason == .modelNotResident)
        #expect(await h.engine.snapshot().inference?.incidentOpen == true)
        #expect(await h.notifier.received.filter { $0.event == .recovered }.isEmpty)
        h.http.set(h.runner.modelsEndpoint, .ok(Data(#"{"models":[{"name":"model"}]}"#.utf8)))
        h.succeed()
        h.clock.advance(by: 61)
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().isHealthy)
        #expect(await h.notifier.received.filter { $0.event == .recovered }.count == 1)
        h.clock.advance(by: 61)
        _ = await h.engine.stepOnce()
        #expect(await h.notifier.received.filter { $0.event == .recovered }.count == 1)
    }

    @Test func oldFailureCannotKillChildCreatedDuringNotification() async throws {
        let h = Harness()
        let notifier = RestartOnDownNotifier()
        let engine = SupervisorEngine(clock: h.clock, processes: h.processes, http: h.http,
            runner: h.runner, power: FakePowerManager(), notifier: notifier, policy: RestartPolicyConfig())
        await engine.start()
        _ = await engine.stepOnce()
        h.http.set(h.runner.readinessEndpoint, .timedOut)
        await notifier.setCallback { await engine.restart() }
        _ = await engine.stepOnce()
        let newHandle = try #require(h.processes.lastHandle)
        #expect(h.processes.spawnCount == 2)
        #expect(h.processes.isAlive(newHandle))
        #expect(await engine.snapshot().phase == .restarting)
        #expect(await engine.snapshot().api?.status == .unchecked)
    }

    @Test func inferenceTeardownPrecedesNotificationSuspension() async throws {
        let h = Harness()
        let notifier = RestartOnDownNotifier()
        let engine = SupervisorEngine(clock: h.clock, processes: h.processes, http: h.http,
            runner: h.runner, power: FakePowerManager(), notifier: notifier,
            policy: RestartPolicyConfig(startupGrace: 0),
            deepProbe: DeepProbeConfig(model: "model", interval: 60, timeout: 30),
            inFlight: { 0 }, clientTrafficObserved: { true })
        h.succeed()
        await engine.start()
        _ = await engine.stepOnce()
        let handle = try #require(h.processes.lastHandle)
        await notifier.setCallback {
            // A client arriving during notification cannot newly occupy the
            // runner that was authorized for teardown before this await.
            #expect(h.processes.isAlive(handle) == false)
        }
        h.http.set(h.url, .timedOut)
        for _ in 0..<2 { h.clock.advance(by: 61); _ = await engine.stepOnce() }
        #expect(await engine.snapshot().phase == .down)
    }

    @Test func deferralDoesNotRefreshSuccessAndJSONExpiresWithoutAnotherProbe() async throws {
        let h = Harness()
        h.succeed()
        await h.engine.start()
        _ = await h.engine.stepOnce()
        let success = await h.engine.snapshot()
        let checkedAt = try #require(success.inference?.lastCheckedAt)
        #expect(success.inference?.isVerified(asOf: h.clock.now) == true)
        h.clock.advance(by: 61)
        let payload = try #require(JSONSerialization.jsonObject(
            with: ControlRouting.statusJSON(success, now: h.clock.now)) as? [String: Any])
        #expect(payload["inferenceVerified"] as? Bool == false)
        #expect(payload["headline"] as? String == "API responding")
        let wireEvidence = try #require(payload["inference"] as? [String: Any])
        #expect(wireEvidence["lastSuccessAt"] as? String == "1970-01-01T00:16:40Z")
        h.http.set(h.runner.modelsEndpoint, .ok(Data(#"{"models":[]}"#.utf8)))
        _ = await h.engine.stepOnce()
        let deferred = await h.engine.snapshot()
        #expect(deferred.inference?.lastCheckedAt == checkedAt)
        #expect(deferred.inference?.lastResult == .succeeded)
        #expect(deferred.inference?.activity == .deferred)
        #expect(deferred.inference?.isVerified(asOf: h.clock.now) == false)
        #expect(deferred.recovery?.traffic == .observedConnections)
        #expect(deferred.recovery?.trafficVisibility == "partial")
        await h.engine.restart()
        #expect(await h.engine.snapshot().inference?.currentProcess == false)
        #expect(await h.engine.snapshot().inference?.lastSuccessAt == checkedAt)
    }

    @Test(arguments: ["{}", "not JSON", #"{"done":false,"eval_count":1}"#,
                      #"{"done":true,"eval_count":0}"#, #"{"done":true,"eval_count":true}"#,
                      #"{"done":true,"eval_count":1,"error":"failed"}"#])
    func invalidHTTP200CannotResolveAnIncident(body: String) async {
        let h = Harness(observed: false)
        h.http.set(h.url, .timedOut)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        h.http.set(h.url, .ok(Data(body.utf8)))
        h.clock.advance(by: 61)
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().inference?.lastResult == .failed)
        #expect(await h.engine.snapshot().inference?.lastSuccessAt == nil)
        #expect(await h.engine.snapshot().isHealthy == false)
        #expect(h.processes.terminateCount == 0)
    }

    @Test func catalogMembershipCannotAuthorizeAnAutomaticProbe() async {
        let runners: [any Runner] = [MLXRunner(binaryPath: "/fixture/mlx"), OsaurusRunner(binaryPath: "/fixture/osaurus")]
        for runner in runners {
            let h = Harness()
            let engine = SupervisorEngine(clock: h.clock, processes: h.processes, http: h.http,
                runner: runner, power: FakePowerManager(), notifier: h.notifier,
                policy: RestartPolicyConfig(), deepProbe: DeepProbeConfig(model: "model", interval: 60, timeout: 30))
            h.http.set(runner.modelsEndpoint, .ok(Data(#"{"data":[{"id":"model"}]}"#.utf8)))
            await engine.start()
            _ = await engine.stepOnce()
            #expect(await engine.snapshot().api?.status == .responding)
            #expect(await engine.snapshot().inference?.deferredReason == .residencyUnknown)
            #expect(await engine.snapshot().recovery?.withheldReason == .residencyUnknown)
            #expect(h.http.postCount(to: runner.deepReadinessRequest(model: "model")!.url) == 0)
        }
    }

    @Test func observedProcessExitInvalidatesRecentVerificationBeforeRespawn() async throws {
        let h = Harness()
        h.succeed()
        await h.engine.start()
        _ = await h.engine.stepOnce()
        let success = await h.engine.snapshot().inference?.lastSuccessAt
        h.processes.simulateExit(try #require(h.processes.lastHandle),
                                exit: ProcessExit(code: 1, wasSignaled: false))
        _ = await h.engine.stepOnce()
        let state = await h.engine.snapshot()
        #expect(state.phase == .down)
        #expect(state.inference?.isVerified(asOf: h.clock.now) == false)
        #expect(state.inference?.lastSuccessAt == success)
    }

    @Test func requestActivityDistinguishesIdleConnectionsAndUnsettledCancellation() async throws {
        let h = Harness()
        let activity = ClientActivityStore()
        activity.setAvailable(true)
        let engine = SupervisorEngine(clock: h.clock, processes: h.processes, http: h.http,
            runner: h.runner, power: FakePowerManager(), notifier: h.notifier,
            policy: RestartPolicyConfig(), deepProbe: DeepProbeConfig(model: "model", interval: 60, timeout: 30),
            clientActivity: { activity.snapshot() })
        h.succeed()
        await engine.start()
        let id = UUID()
        activity.open(id)
        activity.ingest(Data("GET / HTTP/1.1\r\n\r\n".utf8), id: id, upstream: false)
        _ = await engine.stepOnce()
        #expect(h.http.postCount(to: h.url) == 0)
        #expect(await engine.snapshot().inference?.deferredReason == .proxyRequests)
        activity.ingest(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8), id: id, upstream: true)
        h.clock.advance(by: 61)
        _ = await engine.stepOnce()
        #expect(h.http.postCount(to: h.url) == 1)
        #expect(await engine.snapshot().recovery?.clientActivity?.openConnections == 1)
        #expect(await engine.snapshot().inference?.isVerified(asOf: h.clock.now) == true)
        activity.ingest(Data("POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\nx".utf8), id: id, upstream: false)
        activity.close(id)
        h.clock.advance(by: 61)
        _ = await engine.stepOnce()
        #expect(h.http.postCount(to: h.url) == 1)
        #expect(await engine.snapshot().inference?.deferredReason == .trafficUnknown)
        #expect(await engine.snapshot().recovery?.inferenceRestartEligible == false)
        await engine.restart()
        #expect(activity.snapshot().uncertain) // no ownership witness means restart is not proof
    }

    @Test func requestBeginningDuringProbeWithholdsDestructiveRecovery() async {
        let h = Harness()
        let activity = ClientActivityStore()
        activity.setAvailable(true)
        let id = UUID()
        activity.open(id)
        activity.ingest(Data("GET / HTTP/1.1\r\n\r\n".utf8), id: id, upstream: false)
        activity.ingest(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8), id: id, upstream: true)
        let engine = SupervisorEngine(clock: h.clock, processes: h.processes, http: h.http,
            runner: h.runner, power: FakePowerManager(), notifier: h.notifier,
            policy: RestartPolicyConfig(), deepProbe: DeepProbeConfig(model: "model", interval: 60, timeout: 30),
            clientActivity: { activity.snapshot() })
        h.http.set(h.url, .timedOut)
        await engine.start()
        _ = await engine.stepOnce()
        h.http.onPost { activity.ingest(Data("P".utf8), id: id, upstream: false) }
        h.clock.advance(by: 61)
        _ = await engine.stepOnce()
        #expect(h.processes.terminateCount == 0)
        #expect(await engine.snapshot().inferenceRecoveryWithheld)
    }

    @Test func completionAdaptersRequireBoundedFinishedGeneration() {
        #expect(InferenceCompletion.ollama(Data(#"{"done":true,"eval_count":1}"#.utf8)))
        #expect(!InferenceCompletion.ollama(Data(repeating: 32, count: 65537)))
        #expect(InferenceCompletion.openAI(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Hi"}}]}"#.utf8)))
        #expect(InferenceCompletion.openAI(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":""}}],"usage":{"completion_tokens":1}}"#.utf8)))
        for body in ["{}", #"{"choices":[]}"#,
                     #"{"choices":[{"finish_reason":null,"message":{"content":"Hi"}}]}"#,
                     #"{"choices":[{"finish_reason":"stop","message":{"content":""}}]}"#,
                     #"{"choices":[{"finish_reason":"stop","message":{"content":"Hi"}}],"error":{}}"#] {
            #expect(!InferenceCompletion.openAI(Data(body.utf8)))
        }
        #expect(!InferenceCompletion.openAI(Data(repeating: 32, count: 65537)))
        #expect(LMStudioRunner(binaryPath: "/fixture/lms").reportsLoadedModels)
    }
}
