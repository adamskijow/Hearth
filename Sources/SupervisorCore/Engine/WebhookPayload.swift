// SPDX-License-Identifier: MIT

import Foundation

/// Builds the JSON body Hearth POSTs to a configured webhook on each notification,
/// so it can be wired into your own automation. Pure and testable; the app does
/// the HTTP. The body carries only Hearth's own short status (level, title, body,
/// a machine-readable event kind, and a timestamp), never runner content.
public enum WebhookPayload {
    public static func json(for notification: HearthNotification, timestamp: String) -> Data {
        let object: [String: Any?] = [
            "level": levelString(notification.level),
            "title": notification.title,
            "body": notification.body,
            "event": notification.event.map(eventKind),
            "timestamp": timestamp,
        ]
        let present = object.compactMapValues { $0 }
        return (try? JSONSerialization.data(withJSONObject: present, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func levelString(_ level: NotificationLevel) -> String {
        switch level {
        case .info: return "info"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    /// A stable snake_case identifier for routing, distinct from the human label.
    static func eventKind(_ event: SupervisorEvent) -> String {
        switch event {
        case .started: return "started"
        case .becameHealthy: return "became_healthy"
        case .down: return "down"
        case .restartScheduled: return "restart_scheduled"
        case .restarted: return "restarted"
        case .maintenanceRestart: return "maintenance_restart"
        case .recovered: return "recovered"
        case .enteredFailing: return "failing"
        case .modelsUpdated: return "models_updated"
        case .warmupFinished: return "warmup_finished"
        case .warmupSkippedAfterCrash: return "warmup_skipped_after_crash"
        case .memoryLimitExceeded: return "memory_limit_exceeded"
        case .stopped: return "stopped"
        }
    }
}
