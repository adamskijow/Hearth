// SPDX-License-Identifier: MIT

import Foundation

/// User-owned configuration for the sandboxed companion. It deliberately stores
/// only endpoints and probe policy: no executable paths, process state, or
/// privilege material can cross the App Store product boundary.
public struct MonitorSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var targets: [MonitorTarget]
    public var selectedTargetID: UUID?
    public var alertsEnabled: Bool
    public var alertsSnoozedUntil: Date?

    public init(schemaVersion: Int = MonitorSettings.currentSchemaVersion,
                targets: [MonitorTarget] = [],
                selectedTargetID: UUID? = nil,
                alertsEnabled: Bool = false,
                alertsSnoozedUntil: Date? = nil) {
        self.schemaVersion = schemaVersion
        self.targets = targets
        self.selectedTargetID = selectedTargetID
        self.alertsEnabled = alertsEnabled
        self.alertsSnoozedUntil = alertsSnoozedUntil
        normalizeSelection()
    }

    public var selectedTarget: MonitorTarget? {
        guard let selectedTargetID else { return targets.first }
        return targets.first(where: { $0.id == selectedTargetID }) ?? targets.first
    }

    public mutating func upsert(_ target: MonitorTarget, select: Bool = true) {
        if let index = targets.firstIndex(where: { $0.id == target.id }) {
            targets[index] = target
        } else {
            targets.append(target)
        }
        if select { selectedTargetID = target.id }
        normalizeSelection()
    }

    @discardableResult
    public mutating func removeTarget(id: UUID) -> Bool {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return false }
        targets.remove(at: index)
        normalizeSelection()
        return true
    }

    public mutating func normalizeSelection() {
        guard !targets.isEmpty else {
            selectedTargetID = nil
            return
        }
        if selectedTargetID == nil || !targets.contains(where: { $0.id == selectedTargetID }) {
            selectedTargetID = targets[0].id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, targets, selectedTargetID, alertsEnabled, alertsSnoozedUntil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        targets = try container.decodeIfPresent([MonitorTarget].self, forKey: .targets) ?? []
        selectedTargetID = try container.decodeIfPresent(UUID.self, forKey: .selectedTargetID)
        alertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? false
        alertsSnoozedUntil = try container.decodeIfPresent(Date.self, forKey: .alertsSnoozedUntil)
        normalizeSelection()
    }
}
