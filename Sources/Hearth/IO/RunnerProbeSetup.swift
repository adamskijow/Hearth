// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Runner discovery and explicit inference tests used by the Preferences deep-probe assistant. Catalog
/// discovery never loads a model; the explicit Test action performs the same
/// one-token request the supervisor will later use.
enum RunnerProbeSetup {
    struct TestResult: Sendable {
        var elapsed: TimeInterval
    }

    enum SetupError: LocalizedError {
        case runnerUnavailable
        case http(Int)
        case malformedCatalog
        case unsupportedProbe
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .runnerUnavailable: return "The runner is not answering. Start it, then try again."
            case .http(let status): return "The runner returned HTTP \(status)."
            case .malformedCatalog: return "The runner returned a model list Hearth could not read."
            case .unsupportedProbe: return "Hearth could not build a probe for this runner and model."
            case .timedOut: return "The inference test timed out. Try a smaller model or a longer timeout."
            case .failed(let message): return "The runner request failed: \(message)"
            }
        }
    }

    static func availableModels(config: HearthConfig) async throws -> [AvailableModel] {
        let runner = config.makeRunner()
        let outcome = await URLSessionHTTPClient().get(runner.availableModelsEndpoint, timeout: 5)
        let data: Data
        switch outcome {
        case .ok(let body): data = body
        case .http(let status, _): throw SetupError.http(status)
        case .timedOut, .refused: throw SetupError.runnerUnavailable
        case .failure(let message): throw SetupError.failed(message)
        }
        guard let parsed = try? runner.parseAvailableModels(data) else {
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
                default: return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
            }
    }

    static func test(config: HearthConfig, model: String, http: any HTTPClient = URLSessionHTTPClient()) async throws -> TestResult {
        let runner = config.makeRunner()
        guard let request = runner.deepReadinessRequest(model: model) else {
            throw SetupError.unsupportedProbe
        }
        let started = Date()
        let timeout = DeepProbeConfig(
            model: model,
            interval: config.deepProbeIntervalSeconds,
            timeout: config.deepProbeTimeoutSeconds
        ).effectiveTimeout(modelIsConfirmedResident: false)
        var endpoint = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        endpoint?.port = config.clientPort
        guard let url = endpoint?.url else { throw SetupError.unsupportedProbe }
        let outcome = await http.post(
            url, body: request.body,
            timeout: timeout)
        switch outcome {
        case .ok(let body):
            guard runner.validatesInferenceCompletion(body) else {
                throw SetupError.failed("HTTP success did not contain a completed inference response.")
            }
            return TestResult(elapsed: Date().timeIntervalSince(started))
        case .http(let status, _): throw SetupError.http(status)
        case .timedOut: throw SetupError.timedOut
        case .refused: throw SetupError.runnerUnavailable
        case .failure(let message): throw SetupError.failed(message)
        }
    }
}
