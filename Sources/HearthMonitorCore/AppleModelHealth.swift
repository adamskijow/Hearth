// SPDX-License-Identifier: MIT

import Foundation

/// Settings for the system model built into macOS. Passive availability checks
/// are inexpensive; functional checks generate a tiny response and are therefore
/// separately consented to and deliberately infrequent.
public struct AppleModelMonitorSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var functionalChecksEnabled: Bool
    public var checkIntervalSeconds: TimeInterval
    public var timeoutSeconds: TimeInterval
    public var failureThreshold: Int

    public init(enabled: Bool = true,
                functionalChecksEnabled: Bool = false,
                checkIntervalSeconds: TimeInterval = 900,
                timeoutSeconds: TimeInterval = 30,
                failureThreshold: Int = 2) {
        self.enabled = enabled
        self.functionalChecksEnabled = functionalChecksEnabled
        self.checkIntervalSeconds = checkIntervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.failureThreshold = failureThreshold
    }

    public var clampedCheckInterval: TimeInterval { max(300, checkIntervalSeconds) }
    public var clampedTimeout: TimeInterval { min(120, max(5, timeoutSeconds)) }
    public var clampedFailureThreshold: Int { min(5, max(2, failureThreshold)) }

    public var validationIssues: [String] {
        var issues: [String] = []
        if !checkIntervalSeconds.isFinite || checkIntervalSeconds < 300 {
            issues.append("Apple on-device model checks must be at least 5 minutes apart.")
        }
        if !timeoutSeconds.isFinite || !(5...120).contains(timeoutSeconds) {
            issues.append("Apple on-device model timeout must be between 5 and 120 seconds.")
        }
        if !(2...5).contains(failureThreshold) {
            issues.append("Apple on-device model failures must be confirmed by 2 to 5 checks.")
        }
        return issues
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, functionalChecksEnabled, checkIntervalSeconds, timeoutSeconds, failureThreshold
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        functionalChecksEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .functionalChecksEnabled) ?? defaults.functionalChecksEnabled
        checkIntervalSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .checkIntervalSeconds) ?? defaults.checkIntervalSeconds
        timeoutSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        failureThreshold = try container.decodeIfPresent(
            Int.self, forKey: .failureThreshold) ?? defaults.failureThreshold
    }
}

public enum AppleModelUnavailableReason: String, Codable, Sendable, Equatable {
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case frameworkUnavailable
}

public enum AppleModelAvailability: Sendable, Equatable {
    case available
    case unavailable(AppleModelUnavailableReason)
}

public enum AppleModelFunctionalResult: Sendable, Equatable {
    case completed(TimeInterval)
    case timedOut
    case rateLimited
    case requestStillRunning
    case modelNotReady
    case unsupportedLocale
    case failed(String)
}

/// Narrow dependency surface that keeps the state machine deterministic and
/// lets the real Foundation Models adapter remain in the sandboxed app target.
public protocol AppleModelProbing: Sendable {
    func availability() async -> AppleModelAvailability
    func runFunctionalCheck(timeout: TimeInterval) async -> AppleModelFunctionalResult
}

public enum AppleModelHealthPhase: String, Codable, Sendable, Equatable {
    case checking
    case available
    case healthy
    case slow
    case verifying
    case down
    case unavailable
}

public enum AppleModelHealthFailure: Sendable, Equatable {
    case timedOut
    case generation(String)

    public var plainDescription: String {
        switch self {
        case .timedOut:
            return "Apple's on-device language model was available, but a small response did not finish in time."
        case .generation(let message):
            return "Apple's on-device language model was available, but the functional check failed: \(message)"
        }
    }
}

public struct AppleModelHealthSnapshot: Sendable, Equatable {
    public static let incidentTargetID = UUID(uuidString: "3C710CE4-87F9-4DA0-A52F-E40FC927C29A")!

    public var phase: AppleModelHealthPhase
    public var availability: AppleModelAvailability
    public var checkedAt: Date?
    public var changedAt: Date
    public var healthySince: Date?
    public var functionalCheckedAt: Date?
    public var functionalSucceededAt: Date?
    public var lastLatencySeconds: TimeInterval?
    public var baselineLatencySeconds: TimeInterval?
    public var latencySamples: [TimeInterval]
    public var consecutiveFailures: Int
    public var failure: AppleModelHealthFailure?
    public var deferredReason: String?

    public init(now: Date = Date()) {
        phase = .checking
        availability = .unavailable(.frameworkUnavailable)
        checkedAt = nil
        changedAt = now
        healthySince = nil
        functionalCheckedAt = nil
        functionalSucceededAt = nil
        lastLatencySeconds = nil
        baselineLatencySeconds = nil
        latencySamples = []
        consecutiveFailures = 0
        failure = nil
        deferredReason = nil
    }

    public var isFunctionallyServing: Bool { phase == .healthy || phase == .slow }
    public var hasConfirmedIncident: Bool { phase == .down }
}

/// System-model health orchestration. It never assumes access to Apple's model
/// process and classifies only what the public framework proves.
public actor AppleModelHealthEngine {
    private let settings: AppleModelMonitorSettings
    private let probe: any AppleModelProbing
    private var snapshot: AppleModelHealthSnapshot
    private var lastFunctionalAttemptAt: Date?
    /// The first app-level timeout for a Foundation Models request that may
    /// still be executing inside macOS. Continued execution confirms the same
    /// stall by elapsed timeout windows without launching overlapping work.
    private var stuckRequestTimedOutAt: Date?
    private var checkInFlight = false

    public init(settings: AppleModelMonitorSettings,
                probe: any AppleModelProbing,
                now: Date = Date()) {
        self.settings = settings
        self.probe = probe
        snapshot = AppleModelHealthSnapshot(now: now)
    }

    public func currentSnapshot() -> AppleModelHealthSnapshot { snapshot }

    @discardableResult
    public func check(now: Date = Date(),
                      forceFunctional: Bool = false,
                      functionalChecksAllowed: Bool = true) async -> AppleModelHealthSnapshot {
        guard !checkInFlight else { return snapshot }
        checkInFlight = true
        defer { checkInFlight = false }

        let priorAvailability = snapshot.availability
        let availability = await probe.availability()
        snapshot.checkedAt = now
        snapshot.availability = availability
        snapshot.deferredReason = nil

        guard availability == .available else {
            stuckRequestTimedOutAt = nil
            transition(to: .unavailable, at: now)
            snapshot.healthySince = nil
            snapshot.failure = nil
            snapshot.consecutiveFailures = 0
            return snapshot
        }

        guard settings.functionalChecksEnabled else {
            stuckRequestTimedOutAt = nil
            transition(to: .available, at: now)
            snapshot.failure = nil
            snapshot.consecutiveFailures = 0
            return snapshot
        }

        guard functionalChecksAllowed || forceFunctional else {
            if priorAvailability != .available, snapshot.phase == .unavailable {
                transition(to: .checking, at: now)
            }
            snapshot.deferredReason = "Functional checks are paused to reduce energy or thermal impact."
            return snapshot
        }

        let availabilityRecovered = priorAvailability != .available
        guard forceFunctional || availabilityRecovered
                || functionalCheckIsDue(now: now) || snapshot.failure != nil else {
            return snapshot
        }

        lastFunctionalAttemptAt = now
        let result = await probe.runFunctionalCheck(timeout: settings.clampedTimeout)
        switch result {
        case .completed(let elapsed):
            stuckRequestTimedOutAt = nil
            recordSuccess(elapsed: elapsed, at: now)
        case .timedOut:
            // requestStillRunning identifies the same retained task. A new
            // timedOut result therefore starts a new confirmation window.
            stuckRequestTimedOutAt = now
            snapshot.functionalCheckedAt = now
            recordFailure(.timedOut, at: now)
        case .failed(let message):
            stuckRequestTimedOutAt = nil
            snapshot.functionalCheckedAt = now
            recordFailure(.generation(message), at: now)
        case .rateLimited:
            stuckRequestTimedOutAt = nil
            snapshot.functionalCheckedAt = now
            snapshot.deferredReason = "Apple's on-device model asked Hearth to wait before checking again."
        case .requestStillRunning:
            snapshot.deferredReason = "The previous model request is still running; Hearth will not stack another request."
            confirmContinuingTimeoutIfNeeded(at: now)
        case .modelNotReady:
            stuckRequestTimedOutAt = nil
            snapshot.functionalCheckedAt = now
            snapshot.availability = .unavailable(.modelNotReady)
            transition(to: .unavailable, at: now)
            snapshot.failure = nil
            snapshot.consecutiveFailures = 0
            snapshot.healthySince = nil
        case .unsupportedLocale:
            stuckRequestTimedOutAt = nil
            snapshot.functionalCheckedAt = now
            snapshot.availability = .unavailable(.unsupportedLocale)
            transition(to: .unavailable, at: now)
            snapshot.failure = nil
            snapshot.consecutiveFailures = 0
            snapshot.healthySince = nil
        }
        return snapshot
    }

    /// One request that remains alive across multiple timeout windows is itself
    /// repeated evidence; issuing another request would only make the wedge
    /// worse. Advance the configured confirmation count from elapsed time, at
    /// most to the threshold, and transition to down when it is satisfied.
    private func confirmContinuingTimeoutIfNeeded(at now: Date) {
        guard snapshot.failure == .timedOut,
              let firstTimeout = stuckRequestTimedOutAt else { return }
        let elapsed = max(0, now.timeIntervalSince(firstTimeout))
        let observedWindows = 1 + Int(elapsed / settings.clampedTimeout)
        let desiredFailures = min(
            settings.clampedFailureThreshold,
            max(snapshot.consecutiveFailures, observedWindows))
        while snapshot.consecutiveFailures < desiredFailures {
            recordFailure(.timedOut, at: now)
        }
    }

    private func functionalCheckIsDue(now: Date) -> Bool {
        guard let lastFunctionalAttemptAt else { return true }
        return now.timeIntervalSince(lastFunctionalAttemptAt) >= settings.clampedCheckInterval
    }

    private func recordSuccess(elapsed: TimeInterval, at now: Date) {
        let priorPhase = snapshot.phase
        let baseline = median(snapshot.latencySamples)
        let isSlow = snapshot.latencySamples.count >= 3
            && elapsed >= max(8, (baseline ?? elapsed) * 3)
        snapshot.lastLatencySeconds = elapsed
        snapshot.functionalCheckedAt = now
        snapshot.functionalSucceededAt = now
        snapshot.latencySamples.append(elapsed)
        if snapshot.latencySamples.count > 12 {
            snapshot.latencySamples.removeFirst(snapshot.latencySamples.count - 12)
        }
        snapshot.baselineLatencySeconds = median(snapshot.latencySamples)
        snapshot.consecutiveFailures = 0
        snapshot.failure = nil
        snapshot.deferredReason = nil
        transition(to: isSlow ? .slow : .healthy, at: now)
        if snapshot.healthySince == nil || priorPhase == .down {
            snapshot.healthySince = now
        }
    }

    private func recordFailure(_ failure: AppleModelHealthFailure, at now: Date) {
        snapshot.consecutiveFailures += 1
        snapshot.failure = failure
        snapshot.healthySince = nil
        let confirmed = snapshot.consecutiveFailures >= settings.clampedFailureThreshold
        transition(to: confirmed ? .down : .verifying, at: now)
    }

    private func transition(to phase: AppleModelHealthPhase, at now: Date) {
        if snapshot.phase != phase { snapshot.changedAt = now }
        snapshot.phase = phase
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
