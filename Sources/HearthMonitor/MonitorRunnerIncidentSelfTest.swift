// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

/// A release-only integration gate for the attached runner path. It talks to
/// Hearth's loopback fake runner through the same sandboxed URLSession adapter as
/// the app, but never changes saved Monitor settings or touches a real runner.
enum MonitorRunnerIncidentSelfTest {
    private static let portVariable = "HEARTH_MONITOR_SELF_TEST_PORT"

    static func run() async -> Int32 {
        let rawPort = ProcessInfo.processInfo.environment[portVariable] ?? "44144"
        guard let port = Int(rawPort), (1...65_535).contains(port) else {
            return fail("\(portVariable) must be a valid loopback port.")
        }

        let target = MonitorTarget(
            name: "Isolated Release Runner",
            runner: "ollama",
            host: "127.0.0.1",
            port: port,
            probeModel: "fake-model:latest",
            probeIntervalSeconds: 2,
            probeTimeoutSeconds: 1,
            deepProbeIntervalSeconds: 5,
            deepProbeTimeoutSeconds: 1,
            failureThreshold: 2,
            modelRefreshIntervalSeconds: 5)
        guard target.validationIssues.isEmpty else {
            return fail("The self-test target is invalid: \(target.validationIssues.joined(separator: " "))")
        }

        let http = MonitorHTTPClient()
        let engine = MonitorEngine(target: target, http: http)
        var ledger = MonitorIncidentLedger()
        let start = Date()

        guard await setInferenceWedge(false, port: port, http: http) else {
            return fail("The isolated fake runner is not reachable on port \(port).")
        }

        let healthy = await engine.check(now: start, forceDeepProbe: true)
        guard healthy.phase == .healthy, healthy.deepProbeLastSucceeded == true else {
            return fail("The initial real inference check did not establish health.")
        }
        guard ledger.observe(target: target, snapshot: healthy) == .none else {
            return fail("Initial health unexpectedly changed incident history.")
        }

        guard await setInferenceWedge(true, port: port, http: http) else {
            return fail("Could not put the isolated runner into its inference-only wedge.")
        }

        let firstMiss = await engine.check(
            now: start.addingTimeInterval(2),
            forceDeepProbe: true)
        guard firstMiss.phase == .checking,
              firstMiss.failure == .inferenceTimedOut,
              firstMiss.consecutiveFailures == 1 else {
            await restoreRunner(port: port, http: http)
            return fail("The first inference timeout was not kept provisional.")
        }
        guard ledger.observe(target: target, snapshot: firstMiss) == .none,
              ledger.incidents.isEmpty else {
            await restoreRunner(port: port, http: http)
            return fail("A single inference timeout incorrectly created an incident.")
        }

        let confirmed = await engine.check(
            now: start.addingTimeInterval(4),
            forceDeepProbe: true)
        guard confirmed.phase == .down,
              confirmed.failure == .inferenceTimedOut,
              confirmed.consecutiveFailures == 2 else {
            await restoreRunner(port: port, http: http)
            return fail("The second inference timeout did not confirm the outage.")
        }
        guard case .opened(let incidentID) = ledger.observe(
            target: target,
            snapshot: confirmed,
            at: start.addingTimeInterval(4)),
              let incident = ledger.incident(id: incidentID),
              incident.inferenceLevel else {
            await restoreRunner(port: port, http: http)
            return fail("The confirmed inference outage did not open an inference incident.")
        }

        let pending = MonitorAlertPolicy.pendingOutages(
            in: ledger,
            monitoredTargetIDs: [target.id],
            alertsEnabled: true,
            snoozedUntil: nil,
            now: start.addingTimeInterval(4))
        let outage = MonitorAlertContent.outage(incident)
        guard pending.map(\.id) == [incidentID],
              outage.title.contains("inference is wedged"),
              outage.body.contains("restart the runner") else {
            await restoreRunner(port: port, http: http)
            return fail("The confirmed outage did not produce actionable alert content.")
        }
        _ = ledger.markOutageAlerted(id: incidentID, at: start.addingTimeInterval(4))

        guard await setInferenceWedge(false, port: port, http: http) else {
            return fail("Could not release the isolated inference wedge.")
        }
        let recovered = await engine.check(
            now: start.addingTimeInterval(6),
            forceDeepProbe: true)
        guard recovered.phase == .healthy,
              recovered.failure == nil,
              recovered.deepProbeLastSucceeded == true else {
            return fail("Shallow API health was not followed by verified inference recovery.")
        }
        guard ledger.observe(
            target: target,
            snapshot: recovered,
            at: start.addingTimeInterval(6)) == .recovered(incidentID),
              let closed = ledger.incident(id: incidentID),
              closed.resolution == .recovered else {
            return fail("Verified inference recovery did not close the incident.")
        }

        let recoveries = MonitorAlertPolicy.pendingRecoveries(
            in: ledger,
            alertsEnabled: true,
            snoozedUntil: nil,
            now: start.addingTimeInterval(6))
        let recovery = MonitorAlertContent.recovery(closed)
        guard recoveries.map(\.id) == [incidentID],
              recovery.title == "Isolated Release Runner recovered" else {
            return fail("The closed outage did not produce the expected recovery alert.")
        }

        print("Hearth Monitor runner incident self-test passed: healthy → provisional inference miss → confirmed incident → inference-verified recovery.")
        return 0
    }

    private static func setInferenceWedge(
        _ enabled: Bool,
        port: Int,
        http: MonitorHTTPClient
    ) async -> Bool {
        let state = enabled ? "on" : "off"
        guard let url = URL(string: "http://127.0.0.1:\(port)/__fake/inference-wedge/\(state)") else {
            return false
        }
        if case .ok = await http.get(url, timeout: 2) { return true }
        return false
    }

    private static func restoreRunner(port: Int, http: MonitorHTTPClient) async {
        _ = await setInferenceWedge(false, port: port, http: http)
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(
            Data("Hearth Monitor runner incident self-test failed: \(message)\n".utf8))
        return 1
    }
}
