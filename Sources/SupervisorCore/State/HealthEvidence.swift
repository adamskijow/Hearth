// SPDX-License-Identifier: MIT

import Foundation

/// A shallow HTTP observation, independent of process lifecycle and inference.
public struct APIEvidence: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case unchecked, responding, busy, unavailable }
    public var status: Status = .unchecked
    public var checkedAt: Date?
    public init() {}
}

/// Completed evidence is never replaced by a scheduling decision. History can
/// span a process replacement, but only evidence from the current observation
/// target is current. Attached mode cannot detect an unobserved external restart.
public struct InferenceEvidence: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable { case unchecked, succeeded, failed }
    public enum Activity: String, Codable, Sendable { case idle, checking, deferred }
    public enum Deferral: String, Codable, Sendable {
        case proxyConnections, modelNotResident, residencyUnknown, modelListUnavailable
        case runnerUnsupported, queueFull, apiUnavailable, stopped
    }
    public var model: String?
    public var lastResult: Result = .unchecked
    public var lastCheckedAt: Date?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var validUntil: Date?
    public var currentProcess = false
    public var incidentOpen = false
    public var activity: Activity = .idle
    public var deferredReason: Deferral?
    public init(model: String? = nil) { self.model = model }

    public func isVerified(asOf now: Date) -> Bool {
        currentProcess && lastResult == .succeeded && !incidentOpen
            && (validUntil.map { now < $0 } ?? false)
    }
}

/// Connection visibility is partial even after a client uses the proxy: direct
/// requests to the runner are not observable. Eligibility describes policy,
/// never proof that restarting cannot interrupt a client.
public struct RecoveryEvidence: Encodable, Sendable, Equatable {
    public enum Ownership: String, Codable, Sendable { case managed, attached }
    public enum Traffic: String, Codable, Sendable { case disabled, unused, observedConnections }
    public enum WithheldReason: String, Codable, Sendable {
        case stopped, attached, probeDisabled, residencyUnknown, proxyDisabled, proxyUnused, proxyConnections
    }
    public var ownership: Ownership
    public var traffic: Traffic
    public let trafficVisibility = "partial"
    public var inferenceRestartEligible: Bool
    public var withheldReason: WithheldReason?
    public init(ownership: Ownership, traffic: Traffic, withheldReason: WithheldReason?) {
        self.ownership = ownership
        self.traffic = traffic
        self.withheldReason = withheldReason
        self.inferenceRestartEligible = withheldReason == nil
    }
}
