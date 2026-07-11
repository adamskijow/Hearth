// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Attached-only health orchestration. It performs HTTP requests and updates a
/// snapshot, but contains no process handle and exposes no recovery command.
public actor MonitorEngine {
    private var target: MonitorTarget
    private let http: any HTTPClient
    private var snapshot: MonitorSnapshot
    private var lastDeepProbeAt: Date?
    private var lastModelRefreshAt: Date?
    private var generation = 0
    private var checkInFlight = false

    public init(target: MonitorTarget,
                http: any HTTPClient,
                now: Date = Date()) {
        self.target = target
        self.http = http
        self.snapshot = MonitorSnapshot(
            targetID: target.id,
            now: now,
            deepProbeConfigured: target.normalizedProbeModel != nil)
    }

    public func currentSnapshot() -> MonitorSnapshot { snapshot }

    public func updateTarget(_ updated: MonitorTarget, now: Date = Date()) {
        generation &+= 1
        let endpointChanged = target.id != updated.id
            || target.runner != updated.runner
            || target.scheme != updated.scheme
            || target.host != updated.host
            || target.port != updated.port
        let deepProbeChanged = target.normalizedProbeModel != updated.normalizedProbeModel
        target = updated
        if endpointChanged {
            snapshot = MonitorSnapshot(
                targetID: updated.id,
                now: now,
                deepProbeConfigured: updated.normalizedProbeModel != nil)
            lastDeepProbeAt = nil
            lastModelRefreshAt = nil
        } else if deepProbeChanged {
            snapshot.deepProbeConfigured = updated.normalizedProbeModel != nil
            snapshot.deepProbeLastAt = nil
            snapshot.deepProbeLastSucceeded = nil
            lastDeepProbeAt = nil
        }
    }

    @discardableResult
    public func check(now: Date = Date(), forceDeepProbe: Bool = false) async -> MonitorSnapshot {
        // A timer tick and a user's Check Now can coincide. Do not queue duplicate
        // probes or let an older, slower request overwrite a newer result.
        guard !checkInFlight else { return snapshot }
        checkInFlight = true
        defer { checkInFlight = false }

        let checkedTarget = target
        let checkedGeneration = generation
        let api = MonitorRunnerAPI(target: checkedTarget)
        let shallow = await http.get(
            api.readinessEndpoint,
            timeout: checkedTarget.clampedProbeTimeout)
        guard generation == checkedGeneration else { return snapshot }

        switch shallow {
        case .ok:
            break
        case .http(let status, _) where status == 503:
            snapshot = recordBusy(at: now)
            return snapshot
        case .http(let status, _):
            return recordFailure(.http(status), target: checkedTarget, at: now)
        case .timedOut:
            return recordFailure(.timedOut, target: checkedTarget, at: now)
        case .refused:
            return recordFailure(.unreachable, target: checkedTarget, at: now)
        case .failure(let message):
            return recordFailure(.transport(message), target: checkedTarget, at: now)
        }

        if let model = checkedTarget.normalizedProbeModel,
           forceDeepProbe || snapshot.failure?.isInferenceLevel == true
               || deepProbeIsDue(target: checkedTarget, now: now) {
            lastDeepProbeAt = now
            snapshot.deepProbeLastAt = now
            guard let request = api.deepReadinessRequest(model: model) else {
                snapshot.deepProbeLastSucceeded = false
                return recordFailure(
                    .inferenceTransport("This runner could not build the configured probe."),
                    target: checkedTarget,
                    at: now)
            }
            let deep = await http.post(
                request.url,
                body: request.body,
                timeout: checkedTarget.clampedDeepProbeTimeout)
            guard generation == checkedGeneration else { return snapshot }
            switch deep {
            case .ok:
                snapshot.deepProbeLastSucceeded = true
            case .http(let status, _) where status == 503:
                snapshot.deepProbeLastSucceeded = nil
                snapshot = recordBusy(at: now)
                return snapshot
            case .http(let status, _):
                snapshot.deepProbeLastSucceeded = false
                return recordFailure(.inferenceHTTP(status), target: checkedTarget, at: now)
            case .timedOut:
                snapshot.deepProbeLastSucceeded = false
                return recordFailure(.inferenceTimedOut, target: checkedTarget, at: now)
            case .refused:
                snapshot.deepProbeLastSucceeded = false
                return recordFailure(
                    .inferenceTransport("The runner stopped accepting connections."),
                    target: checkedTarget,
                    at: now)
            case .failure(let message):
                snapshot.deepProbeLastSucceeded = false
                return recordFailure(
                    .inferenceTransport(message), target: checkedTarget, at: now)
            }
        }

        if modelRefreshIsDue(target: checkedTarget, now: now) {
            lastModelRefreshAt = now
            await refreshModels(
                api: api,
                target: checkedTarget,
                generation: checkedGeneration,
                now: now)
            guard generation == checkedGeneration else { return snapshot }
        }
        snapshot = MonitorStateReducer.success(snapshot, phase: .healthy, at: now)
        return snapshot
    }

    private func recordFailure(_ failure: MonitorFailure,
                               target: MonitorTarget,
                               at now: Date) -> MonitorSnapshot {
        snapshot = MonitorStateReducer.failure(
            snapshot,
            reason: failure,
            threshold: target.clampedFailureThreshold,
            at: now)
        return snapshot
    }

    private func recordBusy(at now: Date) -> MonitorSnapshot {
        guard snapshot.failure?.isInferenceLevel == true else {
            return MonitorStateReducer.success(snapshot, phase: .busy, at: now)
        }
        // Busy is a serving signal in steady state, but after a confirmed deep
        // failure it cannot prove recovery. Keep the incident and retry the deep
        // probe as soon as the runner accepts it again.
        if snapshot.phase != .busy { snapshot.changedAt = now }
        snapshot.phase = .busy
        snapshot.checkedAt = now
        snapshot.healthySince = nil
        return snapshot
    }

    private func deepProbeIsDue(target: MonitorTarget, now: Date) -> Bool {
        guard let lastDeepProbeAt else { return true }
        return now.timeIntervalSince(lastDeepProbeAt) >= target.clampedDeepProbeInterval
    }

    private func modelRefreshIsDue(target: MonitorTarget, now: Date) -> Bool {
        guard let lastModelRefreshAt else { return true }
        return now.timeIntervalSince(lastModelRefreshAt) >= target.clampedModelRefreshInterval
    }

    private func refreshModels(api: MonitorRunnerAPI,
                               target: MonitorTarget,
                               generation checkedGeneration: Int,
                               now: Date) async {
        let outcome = await http.get(
            api.modelsEndpoint, timeout: target.clampedProbeTimeout)
        guard generation == checkedGeneration else { return }
        switch outcome {
        case .ok(let data):
            do {
                snapshot.residentModels = try api.parseResidentModels(data)
                snapshot.modelsUpdatedAt = now
                snapshot.modelsNote = nil
            } catch {
                snapshot.modelsNote = "The runner answered, but its model list could not be read."
            }
        case .http(let status, _):
            snapshot.modelsNote = "Model information returned HTTP \(status)."
        case .timedOut:
            snapshot.modelsNote = "Model information timed out."
        case .refused:
            snapshot.modelsNote = "Model information became unavailable."
        case .failure(let message):
            snapshot.modelsNote = "Model information failed: \(message)"
        }
    }
}
