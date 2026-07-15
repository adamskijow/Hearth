// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import SupervisorCore
import Testing
@testable import HearthMonitor

private final class FakeAuthenticatedHTTP: MonitorAuthenticatedHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var outcome: HTTPOutcome
    private(set) var tokens: [String] = []
    private(set) var urls: [URL] = []

    init(_ outcome: HTTPOutcome) { self.outcome = outcome }

    func get(_ url: URL, bearerToken: String, timeout: TimeInterval) async -> HTTPOutcome {
        lock.withLock {
            tokens.append(bearerToken)
            urls.append(url)
            return outcome
        }
    }
}

private final class FakeMonitorSecrets: MonitorSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]

    func token(for targetID: UUID) throws -> String? {
        lock.withLock { values[targetID] }
    }

    func setToken(_ token: String, for targetID: UUID) throws {
        lock.withLock { values[targetID] = token }
    }

    func deleteToken(for targetID: UUID) throws {
        _ = lock.withLock { values.removeValue(forKey: targetID) }
    }

    func runnerToken(for targetID: UUID) throws -> String? { nil }
    func setRunnerToken(_ token: String, for targetID: UUID) throws {}
    func deleteRunnerToken(for targetID: UUID) throws {}
}

private func fullHearthBody(
    runner: String = "ollama",
    mode: String? = "managed",
    access: String? = "statusOnly"
) -> Data {
    var object: [String: Any] = [
        "phase": "healthy",
        "runner": runner,
        "busy": false,
        "models": ["tiny"],
        "restartCount": 2,
        "consecutiveFailures": 0,
        "deepProbeConfigured": true,
        "rebootOnWedge": true,
        "memoryUsedPercent": 42,
        "thermal": "nominal",
    ]
    if let mode { object["mode"] = mode }
    if let access { object["credentialAccess"] = access }
    return try! JSONSerialization.data(withJSONObject: object)
}

@Suite("Full Hearth status client")
struct FullHearthClientTests {
    @Test("Endpoint and status tolerate old and new full Hearth versions")
    func endpointAndCoding() throws {
        let endpoint = FullHearthEndpoint(scheme: "https", host: "gpu.example.test", port: 443)
        #expect(endpoint.url(path: "/status")?.absoluteString == "https://gpu.example.test:443/status")
        #expect(endpoint.validationIssues.isEmpty)
        #expect(endpoint.tokenTransportWarning == nil)
        #expect(FullHearthEndpoint(host: "100.70.1.2").tokenTransportWarning != nil)
        #expect(FullHearthEndpoint(host: "127.0.0.1").tokenTransportWarning == nil)

        let old = try JSONDecoder().decode(
            FullHearthStatus.self,
            from: Data(#"{"phase":"healthy","runner":"ollama"}"#.utf8))
        #expect(old.mode == nil)
        #expect(old.restartCount == 0)
        #expect(old.credentialAccess == nil)
    }

    @Test("Client sends the bearer only to the exact status URL")
    func authenticatedStatus() async throws {
        let http = FakeAuthenticatedHTTP(.ok(fullHearthBody()))
        let client = FullHearthClient(http: http)
        let status = try await client.status(
            endpoint: FullHearthEndpoint(),
            token: "never-print-this-token")
        #expect(status.isManaged == true)
        #expect(status.credentialAccess == "statusOnly")
        #expect(http.tokens == ["never-print-this-token"])
        #expect(http.urls.map(\.path) == ["/status"])
    }

    @Test("Authentication and malformed bodies have distinct guidance")
    func errors() async {
        let unauthorized = FullHearthClient(http: FakeAuthenticatedHTTP(
            .http(status: 401, body: Data())))
        do {
            _ = try await unauthorized.status(endpoint: FullHearthEndpoint(), token: "wrong-token-long-enough")
            Issue.record("expected unauthorized")
        } catch {
            #expect(error as? FullHearthClientError == .unauthorized)
        }

        let malformed = FullHearthClient(http: FakeAuthenticatedHTTP(.ok(Data("{}".utf8))))
        do {
            _ = try await malformed.status(endpoint: FullHearthEndpoint(), token: "valid-token-long-enough")
            Issue.record("expected malformed status")
        } catch {
            #expect(error as? FullHearthClientError == .malformedStatus)
        }
    }
}

@MainActor
@Suite("Full Hearth pairing model")
struct FullHearthPairingModelTests {
    @Test("Status-only token verifies and an endpoint edit invalidates it")
    func leastPrivilegeAndStaleEdit() async {
        let model = FullHearthPairingModel(
            target: MonitorTarget(),
            token: "status-only-token-long-enough",
            client: FullHearthClient(http: FakeAuthenticatedHTTP(.ok(fullHearthBody()))))
        model.test()
        await model.waitForTest()
        #expect(model.isVerified)
        #expect(model.hasLeastPrivilege)
        #expect(model.canSave)
        model.host = "192.168.1.8"
        #expect(!model.isVerified)
        #expect(model.needsRetest)
    }

    @Test("A broad legacy token requires explicit consent")
    func broadCredentialConsent() async {
        let model = FullHearthPairingModel(
            target: MonitorTarget(),
            token: "full-control-token-long-enough",
            client: FullHearthClient(http: FakeAuthenticatedHTTP(
                .ok(fullHearthBody(access: "control")))))
        model.test()
        await model.waitForTest()
        #expect(model.isVerified)
        #expect(model.needsBroadCredentialConsent)
        #expect(!model.canSave)
        model.allowBroadCredential = true
        #expect(model.canSave)
    }

    @Test("A supervisor for another runner cannot be paired")
    func runnerMismatch() async {
        let model = FullHearthPairingModel(
            target: MonitorTarget(runner: "ollama"),
            token: "status-only-token-long-enough",
            client: FullHearthClient(http: FakeAuthenticatedHTTP(
                .ok(fullHearthBody(runner: "mlx")))))
        model.test()
        await model.waitForTest()
        #expect(!model.isVerified)
        #expect(model.feedback.contains("reports mlx"))
    }
}

@MainActor
@Suite("Full Hearth bridge runtime")
struct FullHearthBridgeCoordinatorTests {
    @Test("Managed status is recovery coverage, not a replacement for direct health")
    func managedRecovery() async throws {
        let target = MonitorTarget(fullHearth: FullHearthEndpoint())
        let secrets = FakeMonitorSecrets()
        try secrets.setToken("status-token-long-enough", for: target.id)
        let bridge = FullHearthBridgeCoordinator(
            client: FullHearthClient(http: FakeAuthenticatedHTTP(.ok(fullHearthBody()))),
            secrets: secrets,
            automaticallySchedules: false)
        bridge.apply([target])
        await bridge.refresh(targetID: target.id)
        #expect(bridge.snapshots[target.id]?.phase == .connected)
        #expect(bridge.snapshots[target.id]?.hasManagedRecovery == true)
        #expect(bridge.snapshots[target.id]?.usesLeastPrivilege == true)
    }

    @Test("Missing Keychain token is actionable and does not remove pairing")
    func missingToken() async {
        let target = MonitorTarget(fullHearth: FullHearthEndpoint())
        let bridge = FullHearthBridgeCoordinator(
            client: FullHearthClient(http: FakeAuthenticatedHTTP(.ok(fullHearthBody()))),
            secrets: FakeMonitorSecrets(),
            automaticallySchedules: false)
        bridge.apply([target])
        await bridge.refresh(targetID: target.id)
        #expect(bridge.snapshots[target.id]?.phase == .credentialMissing)
        #expect(bridge.snapshots[target.id]?.message.contains("Keychain") == true)
    }

    @Test("Diagnostics contain recovery scope but never the token")
    func diagnosticsExcludeSecret() {
        let target = MonitorTarget(fullHearth: FullHearthEndpoint())
        let status = FullHearthStatus(
            phase: "healthy", runner: "ollama", mode: "managed",
            rebootOnWedge: true, credentialAccess: "statusOnly")
        let bridge = FullHearthBridgeSnapshot(
            targetID: target.id,
            phase: .connected,
            checkedAt: Date(),
            message: "Managed recovery active",
            status: status)
        let report = MonitorDiagnosticsText.report(
            target: target,
            snapshot: nil,
            fullHearth: bridge)
        #expect(report.contains("Status only") == false)
        #expect(report.contains("statusOnly"))
        #expect(!report.contains("bearer"))
        #expect(!report.contains("token-long"))
    }
}
