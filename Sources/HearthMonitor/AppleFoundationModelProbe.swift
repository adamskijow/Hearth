// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The only type in Hearth that touches Apple's Foundation Models framework.
/// One timed-out generation may continue inside the OS, so the actor retains it
/// and refuses to start another until it actually finishes. This containment is
/// more important than producing a quick second timeout.
actor AppleFoundationModelProbe: AppleModelProbing {
    typealias Operation = @Sendable () async -> AppleModelFunctionalResult

    private let operation: Operation
    private var inFlight: (id: UUID, task: Task<AppleModelFunctionalResult, Never>)?

    init(operation: Operation? = nil) {
        self.operation = operation ?? { await Self.performSystemCanary() }
    }

    func availability() -> AppleModelAvailability {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable(.deviceNotEligible)
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable(.appleIntelligenceNotEnabled)
            case .unavailable(.modelNotReady):
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.frameworkUnavailable)
            }
        }
#endif
        return .unavailable(.unsupportedOS)
    }

    func runFunctionalCheck(timeout: TimeInterval) async -> AppleModelFunctionalResult {
        guard inFlight == nil else { return .requestStillRunning }
        let id = UUID()
        let operation = self.operation
        let task = Task { await operation() }
        inFlight = (id, task)
        Task { [weak self] in
            _ = await task.value
            await self?.finished(id: id)
        }
        return await Self.firstResult(from: task, timeout: timeout)
    }

    private func finished(id: UUID) {
        if inFlight?.id == id { inFlight = nil }
    }

    private static func firstResult(
        from task: Task<AppleModelFunctionalResult, Never>,
        timeout: TimeInterval
    ) async -> AppleModelFunctionalResult {
        await withCheckedContinuation { continuation in
            let race = AppleModelProbeRace(continuation)
            Task {
                let result = await task.value
                race.resolve(result)
            }
            Task {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    race.resolve(.timedOut)
                } catch {
                    // The generation waiter owns completion if this timer is cancelled.
                }
            }
        }
    }

    private static func performSystemCanary() async -> AppleModelFunctionalResult {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return .failed("This version of macOS does not provide Foundation Models.")
        }
        return await performCanary()
#else
        return .failed("The installed SDK does not contain Foundation Models.")
#endif
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func performCanary() async -> AppleModelFunctionalResult {
        let clock = ContinuousClock()
        let started = clock.now
        let session = LanguageModelSession(
            instructions: "You are completing a private device health check. Follow the tiny response request exactly.")
        do {
            let response = try await session.respond(
                to: "Reply with only: ready",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 4))
            guard !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed("The model returned an empty response.")
            }
            let elapsed = started.duration(to: clock.now)
            return .completed(elapsed.timeInterval)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited:
                return .rateLimited
            case .concurrentRequests:
                return .requestStillRunning
            case .assetsUnavailable:
                return .modelNotReady
            case .unsupportedLanguageOrLocale:
                return .unsupportedLocale
            case .guardrailViolation, .refusal:
                return .failed("The system model declined the fixed health-check prompt.")
            case .exceededContextWindowSize, .unsupportedGuide, .decodingFailure:
                return .failed(error.localizedDescription)
            @unknown default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
#endif
}

private final class AppleModelProbeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppleModelFunctionalResult, Never>?

    init(_ continuation: CheckedContinuation<AppleModelFunctionalResult, Never>) {
        self.continuation = continuation
    }

    func resolve(_ result: AppleModelFunctionalResult) {
        let pending = lock.withLock { () -> CheckedContinuation<AppleModelFunctionalResult, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: result)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
