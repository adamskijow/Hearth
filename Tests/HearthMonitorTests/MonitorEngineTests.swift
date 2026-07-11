// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore
import Testing
@testable import HearthMonitorCore

@Suite("Monitor engine")
struct MonitorEngineTests {
    private let now = Date(timeIntervalSince1970: 5_000)

    @Test("Healthy Ollama includes resident models")
    func healthyWithModels() async {
        let target = MonitorTarget(failureThreshold: 2)
        let api = MonitorRunnerAPI(target: target)
        let http = MonitorFakeHTTPClient()
        http.set(api.readinessEndpoint, outcome: .ok(Data("{\"version\":\"1\"}".utf8)))
        http.set(api.modelsEndpoint, outcome: .ok(Data("""
        {"models":[{"name":"qwen:small","size":1234}]}
        """.utf8)))
        let engine = MonitorEngine(target: target, http: http, now: now)

        let snapshot = await engine.check(now: now)
        #expect(snapshot.phase == .healthy)
        #expect(snapshot.residentModels.map(\.name) == ["qwen:small"])
        #expect(snapshot.modelsNote == nil)
    }

    @Test("503 is busy and does not become a failure")
    func busy() async {
        let target = MonitorTarget()
        let api = MonitorRunnerAPI(target: target)
        let http = MonitorFakeHTTPClient()
        http.set(api.readinessEndpoint, outcome: .http(status: 503, body: Data()))
        let engine = MonitorEngine(target: target, http: http, now: now)

        let snapshot = await engine.check(now: now)
        #expect(snapshot.phase == .busy)
        #expect(snapshot.failure == nil)
        #expect(snapshot.consecutiveFailures == 0)
    }

    @Test("A real inference timeout is distinguished from API health")
    func deepProbeTimeout() async throws {
        let target = MonitorTarget(probeModel: "tiny", failureThreshold: 1)
        let api = MonitorRunnerAPI(target: target)
        let request = try #require(api.deepReadinessRequest(model: "tiny"))
        let http = MonitorFakeHTTPClient()
        http.set(api.readinessEndpoint, outcome: .ok(Data()))
        http.set(request.url, outcome: .timedOut)
        let engine = MonitorEngine(target: target, http: http, now: now)

        let snapshot = await engine.check(now: now)
        #expect(snapshot.phase == .down)
        #expect(snapshot.failure == .inferenceTimedOut)
        #expect(snapshot.deepProbeLastSucceeded == false)
        #expect(http.postCount(request.url) == 1)
    }

    @Test("Model-list failure does not turn a serving runner red")
    func modelMetadataIsNonCritical() async {
        let target = MonitorTarget()
        let api = MonitorRunnerAPI(target: target)
        let http = MonitorFakeHTTPClient()
        http.set(api.readinessEndpoint, outcome: .ok(Data()))
        http.set(api.modelsEndpoint, outcome: .ok(Data("not json".utf8)))
        let engine = MonitorEngine(target: target, http: http, now: now)

        let snapshot = await engine.check(now: now)
        #expect(snapshot.phase == .healthy)
        #expect(snapshot.modelsNote != nil)
    }

    @Test("Deep probes obey their slower cadence")
    func deepProbeCadence() async throws {
        let target = MonitorTarget(
            probeModel: "tiny",
            deepProbeIntervalSeconds: 60,
            failureThreshold: 1)
        let api = MonitorRunnerAPI(target: target)
        let request = try #require(api.deepReadinessRequest(model: "tiny"))
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        let engine = MonitorEngine(target: target, http: http, now: now)

        _ = await engine.check(now: now)
        _ = await engine.check(now: now.addingTimeInterval(10))
        #expect(http.postCount(request.url) == 1)
        _ = await engine.check(now: now.addingTimeInterval(60))
        #expect(http.postCount(request.url) == 2)
    }

    @Test("Inference failure must pass inference again before recovery")
    func inferenceRecoveryIsVerified() async throws {
        let target = MonitorTarget(
            probeModel: "tiny",
            deepProbeIntervalSeconds: 60,
            failureThreshold: 1)
        let api = MonitorRunnerAPI(target: target)
        let request = try #require(api.deepReadinessRequest(model: "tiny"))
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        http.set(request.url, outcome: .timedOut)
        let engine = MonitorEngine(target: target, http: http, now: now)

        let failed = await engine.check(now: now)
        #expect(failed.phase == .down)
        _ = await engine.check(now: now.addingTimeInterval(10))
        #expect(http.postCount(request.url) == 2)

        http.set(request.url, outcome: .ok(Data()))
        let recovered = await engine.check(now: now.addingTimeInterval(20))
        #expect(recovered.phase == .healthy)
        #expect(http.postCount(request.url) == 3)
    }

    @Test("An old check cannot overwrite a changed target")
    func staleCheckIsDiscarded() async {
        let first = MonitorTarget(runner: "ollama")
        let second = MonitorTarget(runner: "mlx")
        let firstAPI = MonitorRunnerAPI(target: first)
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        http.setDelay(nanoseconds: 50_000_000)
        let engine = MonitorEngine(target: first, http: http, now: now)

        let task = Task { await engine.check(now: now) }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await engine.updateTarget(second, now: now.addingTimeInterval(1))
        _ = await task.value

        let current = await engine.currentSnapshot()
        #expect(current.targetID == second.id)
        #expect(current.phase == .checking)
        #expect(http.getCount(firstAPI.readinessEndpoint) == 1)
    }

    @Test("Overlapping checks collapse into one request")
    func overlappingChecksCollapse() async {
        let target = MonitorTarget()
        let api = MonitorRunnerAPI(target: target)
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        http.setDelay(nanoseconds: 50_000_000)
        let engine = MonitorEngine(target: target, http: http, now: now)

        async let first = engine.check(now: now)
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let second = engine.check(now: now)
        _ = await (first, second)
        #expect(http.getCount(api.readinessEndpoint) == 1)
    }

    @Test("Discovery returns only compatible responding endpoints")
    func discovery() async {
        let http = MonitorFakeHTTPClient()
        let ollama = MonitorRunnerAPI(target: MonitorTarget(runner: "ollama"))
        let mlx = MonitorRunnerAPI(target: MonitorTarget(runner: "mlx"))
        http.set(ollama.readinessEndpoint, outcome: .ok(Data(#"{"version":"1"}"#.utf8)))
        http.set(mlx.readinessEndpoint, outcome: .http(status: 503, body: Data()))

        let found = await MonitorDiscovery.discover(http: http)
        #expect(found.map(\.kind) == [.ollama, .mlx])
    }

    @Test("Discovery rejects an unrelated 200 response")
    func discoveryRejectsUnrelatedService() async {
        let http = MonitorFakeHTTPClient()
        let ollama = MonitorRunnerAPI(target: MonitorTarget(runner: "ollama"))
        http.set(ollama.readinessEndpoint, outcome: .ok(Data("hello".utf8)))
        #expect(await MonitorDiscovery.discover(http: http).isEmpty)
    }

    @Test("Busy cannot falsely close a confirmed inference incident")
    func busyDoesNotVerifyInferenceRecovery() async throws {
        let target = MonitorTarget(probeModel: "tiny", failureThreshold: 1)
        let api = MonitorRunnerAPI(target: target)
        let request = try #require(api.deepReadinessRequest(model: "tiny"))
        let http = MonitorFakeHTTPClient(default: .ok(Data()))
        http.set(request.url, outcome: .timedOut)
        let engine = MonitorEngine(target: target, http: http, now: now)

        _ = await engine.check(now: now)
        http.set(api.readinessEndpoint, outcome: .http(status: 503, body: Data()))
        let busy = await engine.check(now: now.addingTimeInterval(2))
        #expect(busy.phase == .busy)
        #expect(busy.failure == .inferenceTimedOut)
        #expect(!busy.isServing)

        http.set(api.readinessEndpoint, outcome: .ok(Data()))
        http.set(request.url, outcome: .http(status: 503, body: Data()))
        let deepBusy = await engine.check(now: now.addingTimeInterval(4))
        #expect(deepBusy.phase == .busy)
        #expect(deepBusy.failure == .inferenceTimedOut)
        #expect(!deepBusy.isServing)

        http.set(request.url, outcome: .ok(Data()))
        let recovered = await engine.check(now: now.addingTimeInterval(6))
        #expect(recovered.phase == .healthy)
        #expect(recovered.failure == nil)
    }
}
