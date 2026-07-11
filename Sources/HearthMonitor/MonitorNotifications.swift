// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import UserNotifications

enum MonitorNotificationPermission: Sendable, Equatable {
    case notDetermined
    case enabled
    case denied
}

struct MonitorAlertMessage: Sendable, Equatable {
    var title: String
    var body: String
}

enum MonitorAlertContent {
    static func outage(_ incident: MonitorIncident) -> MonitorAlertMessage {
        MonitorAlertMessage(
            title: incident.inferenceLevel
                ? "\(incident.targetName) inference is wedged"
                : "\(incident.targetName) is down",
            body: incident.cause + " Hearth Monitor is attached-only and cannot restart it.")
    }

    static func recovery(_ incident: MonitorIncident) -> MonitorAlertMessage {
        MonitorAlertMessage(
            title: "\(incident.targetName) recovered",
            body: "The runner is serving again after \(MonitorPresentation.duration(incident.duration)).")
    }
}

@MainActor
final class MonitorLocalNotifier {
    private let center = UNUserNotificationCenter.current()

    func permission() async -> MonitorNotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .enabled
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestPermission() async -> MonitorNotificationPermission {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return .denied
        }
        return await permission()
    }

    @discardableResult
    func deliver(_ message: MonitorAlertMessage,
                 incidentID: UUID,
                 targetID: UUID,
                 kind: String) async -> Bool {
        guard await permission() == .enabled else { return false }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        content.threadIdentifier = targetID.uuidString
        content.userInfo = ["targetID": targetID.uuidString, "incidentID": incidentID.uuidString]
        let request = UNNotificationRequest(
            identifier: "hearth-monitor.\(incidentID.uuidString).\(kind)",
            content: content,
            trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
