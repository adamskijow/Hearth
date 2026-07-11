// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Read-only calls used by onboarding and Preferences. Listing models never
/// loads one; only the explicitly labeled inference test sends the one-token
/// request used for ongoing wedge detection.
public enum MonitorProbeSetup {
    public struct ConnectionResult: Sendable, Equatable {
        public var isBusy: Bool
        public var elapsed: TimeInterval

        public init(isBusy: Bool, elapsed: TimeInterval) {
            self.isBusy = isBusy
            self.elapsed = elapsed
        }
    }

    public struct InferenceResult: Sendable, Equatable {
        public var elapsed: TimeInterval

        public init(elapsed: TimeInterval) {
            self.elapsed = elapsed
        }
    }

    public enum SetupError: LocalizedError, Sendable, Equatable {
        case invalidTarget(String)
        case runnerUnavailable
        case timedOut
        case http(Int)
        case malformedCatalog
        case unsupportedProbe
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidTarget(let message): return message
            case .runnerUnavailable:
                return "The runner is not accepting connections. Start it or check the address, then try again."
            case .timedOut:
                return "The runner did not answer in time. Check the address or try a longer timeout."
            case .http(let status): return "The runner returned HTTP \(status)."
            case .malformedCatalog:
                return "The runner answered, but its model list could not be read."
            case .unsupportedProbe:
                return "Hearth Monitor could not build an inference check for this runner and model."
            case .failed(let message): return "The runner request failed: \(message)"
            }
        }
    }

    public static func checkConnection(target: MonitorTarget,
                                       http: any HTTPClient) async throws -> ConnectionResult {
        try validate(target)
        let api = MonitorRunnerAPI(target: target)
        let started = Date()
        let outcome = await http.get(api.readinessEndpoint, timeout: target.clampedProbeTimeout)
        let elapsed = Date().timeIntervalSince(started)
        switch outcome {
        case .ok: return ConnectionResult(isBusy: false, elapsed: elapsed)
        case .http(let status, _) where status == 503:
            return ConnectionResult(isBusy: true, elapsed: elapsed)
        default: throw map(outcome)
        }
    }

    public static func availableModels(target: MonitorTarget,
                                       http: any HTTPClient) async throws -> [AvailableModel] {
        try validate(target)
        let api = MonitorRunnerAPI(target: target)
        let outcome = await http.get(api.availableModelsEndpoint, timeout: max(5, target.clampedProbeTimeout))
        let data: Data
        switch outcome {
        case .ok(let body): data = body
        default: throw map(outcome)
        }
        guard let parsed = try? api.parseAvailableModels(data) else {
            throw SetupError.malformedCatalog
        }
        var seen = Set<String>()
        return parsed
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0.name).inserted }
            .sorted { left, right in
                switch (left.sizeBytes, right.sizeBytes) {
                case let (a?, b?) where a != b: return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
            }
    }

    public static func testInference(target: MonitorTarget,
                                     model: String,
                                     http: any HTTPClient) async throws -> InferenceResult {
        try validate(target)
        let api = MonitorRunnerAPI(target: target)
        guard let request = api.deepReadinessRequest(model: model) else {
            throw SetupError.unsupportedProbe
        }
        let started = Date()
        let outcome = await http.post(
            request.url,
            body: request.body,
            timeout: target.clampedDeepProbeTimeout)
        switch outcome {
        case .ok: return InferenceResult(elapsed: Date().timeIntervalSince(started))
        default: throw map(outcome)
        }
    }

    private static func validate(_ target: MonitorTarget) throws {
        if let issue = target.validationIssues.first { throw SetupError.invalidTarget(issue) }
    }

    private static func map(_ outcome: HTTPOutcome) -> SetupError {
        switch outcome {
        case .ok: return .failed("Unexpected response state.")
        case .http(let status, _): return .http(status)
        case .timedOut: return .timedOut
        case .refused: return .runnerUnavailable
        case .failure(let message): return .failed(message)
        }
    }
}
