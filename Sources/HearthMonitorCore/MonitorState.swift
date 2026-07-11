// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

public enum MonitorPhase: String, Codable, Sendable, Equatable {
    case checking
    case healthy
    case busy
    case down
}

public enum MonitorFailure: Sendable, Equatable {
    case unreachable
    case timedOut
    case http(Int)
    case transport(String)
    case inferenceTimedOut
    case inferenceHTTP(Int)
    case inferenceTransport(String)

    public var isInferenceLevel: Bool {
        switch self {
        case .inferenceTimedOut, .inferenceHTTP, .inferenceTransport: return true
        default: return false
        }
    }

    public var plainDescription: String {
        switch self {
        case .unreachable:
            return "The runner is not accepting connections."
        case .timedOut:
            return "The runner accepted a connection but did not answer in time."
        case .http(let status):
            return "The runner answered with HTTP \(status)."
        case .transport(let message):
            return "The runner check failed: \(message)"
        case .inferenceTimedOut:
            return "The API answered, but a real one-token inference did not finish in time."
        case .inferenceHTTP(let status):
            return "The API answered, but the inference check returned HTTP \(status)."
        case .inferenceTransport(let message):
            return "The API answered, but the inference check failed: \(message)"
        }
    }
}

public struct MonitorSnapshot: Sendable, Equatable {
    public var targetID: UUID
    public var phase: MonitorPhase
    public var checkedAt: Date?
    public var changedAt: Date
    public var healthySince: Date?
    public var consecutiveFailures: Int
    public var failure: MonitorFailure?
    public var residentModels: [ResidentModel]
    public var modelsUpdatedAt: Date?
    public var modelsNote: String?
    public var deepProbeConfigured: Bool
    public var deepProbeLastAt: Date?
    public var deepProbeLastSucceeded: Bool?

    public init(targetID: UUID, now: Date, deepProbeConfigured: Bool = false) {
        self.targetID = targetID
        self.phase = .checking
        self.checkedAt = nil
        self.changedAt = now
        self.healthySince = nil
        self.consecutiveFailures = 0
        self.failure = nil
        self.residentModels = []
        self.modelsUpdatedAt = nil
        self.modelsNote = nil
        self.deepProbeConfigured = deepProbeConfigured
        self.deepProbeLastAt = nil
        self.deepProbeLastSucceeded = nil
    }

    public var isServing: Bool {
        phase == .healthy || (phase == .busy && failure == nil)
    }
    public var isConfirmingFailure: Bool { phase == .checking && failure != nil }
}

/// Pure transition logic: one transient miss becomes a visible confirming state,
/// not a false outage; recovery is immediate once the runner answers again.
public enum MonitorStateReducer {
    public static func success(_ prior: MonitorSnapshot,
                               phase: MonitorPhase,
                               at now: Date) -> MonitorSnapshot {
        precondition(phase == .healthy || phase == .busy)
        var next = prior
        next.phase = phase
        next.checkedAt = now
        next.consecutiveFailures = 0
        next.failure = nil
        if prior.phase != phase { next.changedAt = now }
        // A single provisional miss never became an incident, so recovering from
        // `.checking` must preserve the original healthy-since timestamp. Only a
        // confirmed down state (or the very first success) begins a new run.
        if prior.phase == .down || prior.healthySince == nil {
            next.healthySince = now
        }
        return next
    }

    public static func failure(_ prior: MonitorSnapshot,
                               reason: MonitorFailure,
                               threshold: Int,
                               at now: Date) -> MonitorSnapshot {
        var next = prior
        next.checkedAt = now
        next.consecutiveFailures += 1
        next.failure = reason
        let phase: MonitorPhase = next.consecutiveFailures >= max(1, threshold) ? .down : .checking
        if prior.phase != phase { next.changedAt = now }
        next.phase = phase
        if phase == .down { next.healthySince = nil }
        return next
    }
}
