// SPDX-License-Identifier: MIT

import Foundation

public enum MonitorIncidentResolution: String, Codable, Sendable, Equatable {
    case recovered
    case monitoringStopped
}

/// A confirmed outage only. Provisional single-check misses never enter history,
/// keeping the incident list aligned with what Monitor actually told the user.
public struct MonitorIncident: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var targetID: UUID
    public var targetName: String
    public var startedAt: Date
    public var lastObservedAt: Date
    public var endedAt: Date?
    public var resolution: MonitorIncidentResolution?
    public var cause: String
    public var inferenceLevel: Bool
    public var outageAlertedAt: Date?
    public var recoveryAlertedAt: Date?

    public init(id: UUID = UUID(),
                targetID: UUID,
                targetName: String,
                startedAt: Date,
                lastObservedAt: Date,
                endedAt: Date? = nil,
                resolution: MonitorIncidentResolution? = nil,
                cause: String,
                inferenceLevel: Bool,
                outageAlertedAt: Date? = nil,
                recoveryAlertedAt: Date? = nil) {
        self.id = id
        self.targetID = targetID
        self.targetName = targetName
        self.startedAt = startedAt
        self.lastObservedAt = lastObservedAt
        self.endedAt = endedAt
        self.resolution = resolution
        self.cause = cause
        self.inferenceLevel = inferenceLevel
        self.outageAlertedAt = outageAlertedAt
        self.recoveryAlertedAt = recoveryAlertedAt
    }

    public var duration: TimeInterval {
        max(0, (endedAt ?? lastObservedAt).timeIntervalSince(startedAt))
    }
}

public enum MonitorIncidentEvent: Sendable, Equatable {
    case none
    case opened(UUID)
    case updated(UUID)
    case recovered(UUID)
    case monitoringStopped(UUID)

    public var incidentID: UUID? {
        switch self {
        case .none: return nil
        case .opened(let id), .updated(let id), .recovered(let id), .monitoringStopped(let id):
            return id
        }
    }
}

/// Bounded, pure incident reducer. Alert delivery markers live beside each
/// incident so relaunching the app cannot spam the same outage notification.
public struct MonitorIncidentLedger: Codable, Sendable, Equatable {
    public static let defaultLimit = 500

    public var incidents: [MonitorIncident]
    public var limit: Int

    public init(incidents: [MonitorIncident] = [], limit: Int = defaultLimit) {
        self.incidents = incidents
        self.limit = max(10, limit)
        normalize()
    }

    @discardableResult
    public mutating func observe(target: MonitorTarget,
                                snapshot: MonitorSnapshot,
                                at observedAt: Date? = nil) -> MonitorIncidentEvent {
        let now = observedAt ?? snapshot.checkedAt ?? Date()
        if snapshot.phase == .down {
            let cause = snapshot.failure?.plainDescription ?? "The runner stopped responding."
            let inference = snapshot.failure?.isInferenceLevel == true
            if let index = incidents.firstIndex(where: { $0.targetID == target.id && $0.endedAt == nil }) {
                var changed = false
                if incidents[index].targetName != target.name {
                    incidents[index].targetName = target.name
                    changed = true
                }
                if incidents[index].cause != cause || incidents[index].inferenceLevel != inference {
                    incidents[index].cause = cause
                    incidents[index].inferenceLevel = inference
                    changed = true
                }
                // History is durable state, not a second-by-second metrics log.
                // Refresh at most once a minute during a long outage unless its
                // diagnosis changes, keeping disk wakeups low for a menu app.
                if changed || now.timeIntervalSince(incidents[index].lastObservedAt) >= 60 {
                    incidents[index].lastObservedAt = now
                    changed = true
                }
                return changed ? .updated(incidents[index].id) : .none
            }
            let incident = MonitorIncident(
                targetID: target.id,
                targetName: target.name,
                startedAt: snapshot.changedAt,
                lastObservedAt: now,
                cause: cause,
                inferenceLevel: inference)
            incidents.insert(incident, at: 0)
            prune()
            return .opened(incident.id)
        }

        if snapshot.isServing,
           let index = incidents.firstIndex(where: { $0.targetID == target.id && $0.endedAt == nil }) {
            incidents[index].lastObservedAt = now
            incidents[index].endedAt = now
            incidents[index].resolution = .recovered
            return .recovered(incidents[index].id)
        }
        return .none
    }

    /// Apple Foundation Models has no runner endpoint, but confirmed functional
    /// timeouts belong in the same local, bounded incident history and alert
    /// pipeline. Availability states such as disabled or downloading are kept as
    /// actionable status, not mislabeled as wedges.
    @discardableResult
    public mutating func observeAppleModel(
        snapshot: AppleModelHealthSnapshot,
        at observedAt: Date? = nil
    ) -> MonitorIncidentEvent {
        let targetID = AppleModelHealthSnapshot.incidentTargetID
        let targetName = "Apple On-Device Model"
        let now = observedAt ?? snapshot.functionalCheckedAt ?? snapshot.checkedAt ?? Date()
        if snapshot.phase == .down {
            let cause = snapshot.failure?.plainDescription
                ?? "Apple's on-device language model did not complete the functional check."
            if let index = incidents.firstIndex(where: { $0.targetID == targetID && $0.endedAt == nil }) {
                var changed = false
                if incidents[index].cause != cause {
                    incidents[index].cause = cause
                    changed = true
                }
                if changed || now.timeIntervalSince(incidents[index].lastObservedAt) >= 60 {
                    incidents[index].lastObservedAt = now
                    changed = true
                }
                return changed ? .updated(incidents[index].id) : .none
            }
            let incident = MonitorIncident(
                targetID: targetID,
                targetName: targetName,
                startedAt: snapshot.changedAt,
                lastObservedAt: now,
                cause: cause,
                inferenceLevel: true)
            incidents.insert(incident, at: 0)
            prune()
            return .opened(incident.id)
        }

        if snapshot.isFunctionallyServing,
           let index = incidents.firstIndex(where: { $0.targetID == targetID && $0.endedAt == nil }) {
            incidents[index].lastObservedAt = now
            incidents[index].endedAt = now
            incidents[index].resolution = .recovered
            return .recovered(incidents[index].id)
        }
        return .none
    }

    @discardableResult
    public mutating func stopMonitoring(targetID: UUID, at now: Date = Date()) -> MonitorIncidentEvent {
        guard let index = incidents.firstIndex(where: { $0.targetID == targetID && $0.endedAt == nil }) else {
            return .none
        }
        incidents[index].lastObservedAt = now
        incidents[index].endedAt = now
        incidents[index].resolution = .monitoringStopped
        return .monitoringStopped(incidents[index].id)
    }

    public func incident(id: UUID) -> MonitorIncident? {
        incidents.first(where: { $0.id == id })
    }

    public func openIncident(targetID: UUID) -> MonitorIncident? {
        incidents.first(where: { $0.targetID == targetID && $0.endedAt == nil })
    }

    @discardableResult
    public mutating func markOutageAlerted(id: UUID, at date: Date) -> Bool {
        guard let index = incidents.firstIndex(where: { $0.id == id }),
              incidents[index].outageAlertedAt == nil else { return false }
        incidents[index].outageAlertedAt = date
        return true
    }

    @discardableResult
    public mutating func markRecoveryAlerted(id: UUID, at date: Date) -> Bool {
        guard let index = incidents.firstIndex(where: { $0.id == id }),
              incidents[index].recoveryAlertedAt == nil else { return false }
        incidents[index].recoveryAlertedAt = date
        return true
    }

    public mutating func clearClosed() {
        incidents.removeAll(where: { $0.endedAt != nil })
    }

    private enum CodingKeys: String, CodingKey { case incidents, limit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        incidents = try container.decodeIfPresent([MonitorIncident].self, forKey: .incidents) ?? []
        limit = max(10, try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit)
        normalize()
    }

    private mutating func normalize() {
        incidents.sort { $0.startedAt > $1.startedAt }
        prune()
    }

    private mutating func prune() {
        guard incidents.count > limit else { return }
        let open = incidents.filter { $0.endedAt == nil }
        let closed = incidents.filter { $0.endedAt != nil }
        incidents = open + closed.prefix(max(0, limit - open.count))
        incidents.sort { $0.startedAt > $1.startedAt }
    }
}
