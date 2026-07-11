// SPDX-License-Identifier: MIT

import Foundation

/// Pure alert eligibility. Delivery and system permission stay in the app, while
/// snooze/relaunch behavior remains deterministic under tests.
public enum MonitorAlertPolicy {
    public static func pendingOutages(
        in ledger: MonitorIncidentLedger,
        monitoredTargetIDs: Set<UUID>,
        alertsEnabled: Bool,
        snoozedUntil: Date?,
        now: Date
    ) -> [MonitorIncident] {
        guard alertsEnabled, !(snoozedUntil.map { $0 > now } ?? false) else { return [] }
        return ledger.incidents.filter {
            $0.endedAt == nil
                && $0.outageAlertedAt == nil
                && monitoredTargetIDs.contains($0.targetID)
        }
    }

    public static func pendingRecoveries(
        in ledger: MonitorIncidentLedger,
        alertsEnabled: Bool,
        snoozedUntil: Date?,
        now: Date,
        maximumAge: TimeInterval = 300
    ) -> [MonitorIncident] {
        guard alertsEnabled, !(snoozedUntil.map { $0 > now } ?? false) else { return [] }
        return ledger.incidents.filter {
            guard $0.resolution == .recovered,
                  let endedAt = $0.endedAt else { return false }
            return $0.outageAlertedAt != nil
                && $0.recoveryAlertedAt == nil
                && now.timeIntervalSince(endedAt) >= 0
                && now.timeIntervalSince(endedAt) <= max(0, maximumAge)
        }
    }
}

public enum MonitorSnoozeSchedule {
    public static func tomorrowMorning(from now: Date,
                                       hour: Int = 8,
                                       calendar: Calendar = .current) -> Date {
        let today = calendar.date(
            bySettingHour: min(23, max(0, hour)),
            minute: 0,
            second: 0,
            of: now) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
            ?? now.addingTimeInterval(86_400)
    }
}
