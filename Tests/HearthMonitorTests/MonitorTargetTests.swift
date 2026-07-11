// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore
import Testing
@testable import HearthMonitorCore

@Suite("Monitor target and settings")
struct MonitorTargetTests {
    @Test("A target round-trips every user-visible connection field")
    func targetRoundTrip() throws {
        let target = MonitorTarget(
            name: "Studio Mac",
            runner: "mlx",
            scheme: "https",
            host: "studio.example.test",
            port: 9443,
            probeModel: "tiny",
            probeIntervalSeconds: 12,
            probeTimeoutSeconds: 4,
            deepProbeIntervalSeconds: 90,
            deepProbeTimeoutSeconds: 35,
            failureThreshold: 3,
            modelRefreshIntervalSeconds: 45,
            fullHearth: FullHearthEndpoint(scheme: "https", host: "studio.example.test", port: 9444))

        let decoded = try JSONDecoder().decode(
            MonitorTarget.self,
            from: JSONEncoder().encode(target))
        #expect(decoded == target)
    }

    @Test("Older target data defaults to local HTTP")
    func missingSchemeDefaultsToHTTP() throws {
        let data = Data(#"{"name":"Local Ollama","runner":"ollama","host":"127.0.0.1","port":11434}"#.utf8)
        let decoded = try JSONDecoder().decode(MonitorTarget.self, from: data)
        #expect(decoded.scheme == "http")
        #expect(decoded.validationIssues.isEmpty)
    }

    @Test("HTTPS rewrites every runner request")
    func httpsEndpoints() throws {
        let target = MonitorTarget(runner: "ollama", scheme: "https")
        let api = MonitorRunnerAPI(target: target)
        #expect(api.readinessEndpoint.scheme == "https")
        #expect(api.modelsEndpoint.scheme == "https")
        #expect(api.availableModelsEndpoint.scheme == "https")
        #expect(try #require(api.deepReadinessRequest(model: "tiny")).url.scheme == "https")
    }

    @Test("Target validation catches unsafe form values without rejecting private HTTP")
    func validationAndAdvisory() {
        var invalid = MonitorTarget(name: " ", scheme: "http", host: "https://host/path", port: 0)
        invalid.runner = "mystery"
        #expect(invalid.validationIssues.count == 4)
        #expect(MonitorTarget(host: "192.168.1.20").transportAdvisory == nil)
        #expect(MonitorTarget(host: "runner.example.com").transportAdvisory != nil)
        #expect(MonitorTarget(scheme: "https", host: "runner.example.com").transportAdvisory == nil)
        var nonFinite = MonitorTarget()
        nonFinite.probeIntervalSeconds = .nan
        #expect(nonFinite.validationIssues.contains(where: { $0.contains("Check interval") }))
    }

    @Test("Older settings default alerts to off")
    func oldSettingsDefaultAlertsOff() throws {
        let decoded = try JSONDecoder().decode(
            MonitorSettings.self,
            from: Data(#"{"schemaVersion":1,"targets":[]}"#.utf8))
        #expect(!decoded.alertsEnabled)
        #expect(decoded.alertsSnoozedUntil == nil)
    }

    @Test("Settings repair a stale selection and preserve target identity")
    func settingsSelection() throws {
        let first = MonitorTarget(name: "First")
        let second = MonitorTarget(name: "Second")
        var settings = MonitorSettings(
            targets: [first, second],
            selectedTargetID: UUID())
        #expect(settings.selectedTargetID == first.id)
        settings.upsert(MonitorTarget(id: first.id, name: "Edited"))
        #expect(settings.targets.count == 2)
        #expect(settings.selectedTarget?.name == "Edited")
        let removed = settings.removeTarget(id: first.id)
        #expect(removed)
        #expect(settings.selectedTargetID == second.id)

        let decoded = try JSONDecoder().decode(
            MonitorSettings.self,
            from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

@Suite("Monitor setup probes")
struct MonitorProbeSetupTests {
    @Test("Connection setup accepts busy as serving")
    func busyConnection() async throws {
        let target = MonitorTarget()
        let api = MonitorRunnerAPI(target: target)
        let http = MonitorFakeHTTPClient()
        http.set(api.readinessEndpoint, outcome: .http(status: 503, body: Data()))
        let result = try await MonitorProbeSetup.checkConnection(target: target, http: http)
        #expect(result.isBusy)
    }

    @Test("Model choices are unique and smallest first")
    func sortedCatalog() async throws {
        let target = MonitorTarget()
        let api = MonitorRunnerAPI(target: target)
        let body = Data(#"{"models":[{"name":"large","size":900},{"name":"small","size":100},{"name":"large","size":900}]}"#.utf8)
        let http = MonitorFakeHTTPClient()
        http.set(api.availableModelsEndpoint, outcome: .ok(body))
        let models = try await MonitorProbeSetup.availableModels(target: target, http: http)
        #expect(models.map(\.name) == ["small", "large"])
    }

    @Test("Inference setup uses the configured HTTPS endpoint")
    func inferenceHTTPS() async throws {
        let target = MonitorTarget(scheme: "https", probeModel: "tiny")
        let request = try #require(MonitorRunnerAPI(target: target).deepReadinessRequest(model: "tiny"))
        let http = MonitorFakeHTTPClient()
        http.set(request.url, outcome: .ok(Data()))
        _ = try await MonitorProbeSetup.testInference(target: target, model: "tiny", http: http)
        #expect(http.postCount(request.url) == 1)
    }
}
