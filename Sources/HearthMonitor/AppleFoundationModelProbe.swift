// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The only file in Hearth that touches Apple's Foundation Models framework.
/// One timed-out generation may continue inside the OS, so the actor retains it
/// and refuses to start another until it actually finishes. This containment is
/// more important than producing a quick second timeout.
actor AppleFoundationModelProbe: AppleModelProbing {
    typealias Operation = @Sendable () async -> AppleModelFunctionalResult

    private let operation: Operation
    private let gate: AppleModelRequestGate
    private var inFlight: (
        id: UUID,
        task: Task<AppleModelFunctionalResult, Never>,
        state: AppleModelProbeOperationState
    )?

    init(operation: Operation? = nil, gate: AppleModelRequestGate = AppleModelRequestGate()) {
        self.operation = operation ?? { await Self.performSystemCanary() }
        self.gate = gate
    }

    func availability() -> AppleModelAvailability {
        AppleFoundationModelAvailability.current()
    }

    func runFunctionalCheck(timeout: TimeInterval) async -> AppleModelFunctionalResult {
        if let current = inFlight {
            guard current.state.isCompleted else { return .requestStillRunning }
            inFlight = nil
        }
        let id = UUID()
        guard await gate.acquire(id) else { return .requestStillRunning }
        let operation = self.operation
        let state = AppleModelProbeOperationState()
        let gate = self.gate
        let task = Task {
            let result = await operation()
            await gate.release(id)
            state.markCompleted()
            return result
        }
        inFlight = (id, task, state)
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

/// One app-wide lease prevents a manual lab request and an unattended health
/// canary from competing for Apple's model session. A timed-out request keeps
/// its lease until the underlying task actually exits.
actor AppleModelRequestGate {
    private var owner: UUID?

    func acquire(_ candidate: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }

    func release(_ candidate: UUID) {
        if owner == candidate { owner = nil }
    }
}

actor AppleFoundationModelLab: AppleModelLabRunning {
    private let gate: AppleModelRequestGate
    private var inFlight: (id: UUID, task: Task<AppleModelLabResult, Never>)?

    init(gate: AppleModelRequestGate = AppleModelRequestGate()) {
        self.gate = gate
    }

    func availability() -> AppleModelAvailability {
        AppleFoundationModelAvailability.current()
    }

    func run(
        _ request: AppleModelLabRequest,
        onPartial: @escaping @Sendable (String, TimeInterval?) async -> Void
    ) async -> AppleModelLabResult {
        guard inFlight == nil else { return .busy }
        let submitted = request.normalized
        if let validation = submitted.validationMessage { return .failed(validation) }
        switch AppleFoundationModelAvailability.current() {
        case .available:
            break
        case .unavailable(let reason):
            return .unavailable(reason)
        }

        let id = UUID()
        guard await gate.acquire(id) else { return .busy }
        let gate = self.gate
        let task = Task {
            let result = await Self.performSystemPrompt(submitted, onPartial: onPartial)
            await gate.release(id)
            return result
        }
        inFlight = (id, task)
        let result = await task.value
        if inFlight?.id == id { inFlight = nil }
        return result
    }

    func stop() {
        inFlight?.task.cancel()
    }

    private static func performSystemPrompt(
        _ request: AppleModelLabRequest,
        onPartial: @escaping @Sendable (String, TimeInterval?) async -> Void
    ) async -> AppleModelLabResult {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unavailable(.unsupportedOS) }
        return await performPrompt(request, onPartial: onPartial)
#else
        return .unavailable(.frameworkUnavailable)
#endif
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func performPrompt(
        _ request: AppleModelLabRequest,
        onPartial: @escaping @Sendable (String, TimeInterval?) async -> Void
    ) async -> AppleModelLabResult {
        let clock = ContinuousClock()
        let started = clock.now
        var firstOutputSeconds: TimeInterval?
        var latest = ""
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(
            model: model,
            instructions: request.instructions.isEmpty ? nil : request.instructions)
        let sampling: GenerationOptions.SamplingMode?
        let temperature: Double?
        switch request.sampling {
        case .automatic:
            sampling = nil
            temperature = request.temperature
        case .greedy:
            sampling = .greedy
            temperature = nil
        case .varied:
            sampling = .random(top: 40)
            temperature = request.temperature
        }
        let options = GenerationOptions(
            sampling: sampling,
            temperature: temperature,
            maximumResponseTokens: request.maximumResponseTokens)

        do {
            let stream = session.streamResponse(to: request.prompt, options: options)
            for try await snapshot in stream {
                try Task.checkCancellation()
                let partial = snapshot.content
                guard partial != latest else { continue }
                latest = partial
                if firstOutputSeconds == nil, !partial.isEmpty {
                    firstOutputSeconds = started.duration(to: clock.now).timeInterval
                }
                await onPartial(partial, firstOutputSeconds)
            }
            try Task.checkCancellation()
            guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed("Apple Intelligence returned an empty response.")
            }
            let total = started.duration(to: clock.now).timeInterval
            var responseTokens: Int?
            if #available(macOS 26.4, *) {
                responseTokens = try? await model.tokenCount(for: latest)
            }
            return .completed(
                text: latest,
                metrics: AppleModelLabMetrics(
                    timeToFirstOutputSeconds: firstOutputSeconds,
                    totalSeconds: total,
                    responseTokens: responseTokens))
        } catch is CancellationError {
            return .stopped
        } catch let error as LanguageModelSession.GenerationError {
            if Task.isCancelled { return .stopped }
            switch error {
            case .rateLimited:
                return .failed("Apple Intelligence is rate limited. Wait a moment and try again.")
            case .concurrentRequests:
                return .busy
            case .assetsUnavailable:
                return .unavailable(.modelNotReady)
            case .unsupportedLanguageOrLocale:
                return .unavailable(.unsupportedLocale)
            case .guardrailViolation, .refusal:
                return .failed("Apple Intelligence declined this prompt. Try a different request.")
            case .exceededContextWindowSize:
                return .failed("The prompt is too long for the on-device model context.")
            case .unsupportedGuide, .decodingFailure:
                return .failed(error.localizedDescription)
            @unknown default:
                return .failed(error.localizedDescription)
            }
        } catch {
            if Task.isCancelled { return .stopped }
            return .failed(error.localizedDescription)
        }
    }
#endif
}

private enum AppleFoundationModelAvailability {
    static func current() -> AppleModelAvailability {
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
}

private final class AppleModelProbeOperationState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool { lock.withLock { completed } }

    func markCompleted() {
        lock.withLock { completed = true }
    }
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
