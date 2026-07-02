// SPDX-License-Identifier: MIT

import Foundation
import UserNotifications
import SupervisorCore

/// Delivers notifications through the local Notification Center, for when you are
/// at the machine.
///
/// UNUserNotificationCenter requires a bundled, signed app; calling it from a
/// bare executable would crash. So this guards on a bundle identifier and is a
/// no op without one (for example under `swift run`), leaving ntfy to do the
/// reaching out in that case.
final class LocalNotifier: Notifier, @unchecked Sendable {
    /// Whether local notifications can work in this process (it is bundled).
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Ask for permission. Safe to call once at launch; a no op when unbundled.
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post an app originated notification (setup guidance, a test), not tied to a
    /// supervisor event. A no op when unbundled.
    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func notify(_ notification: HearthNotification) async {
        guard Self.isAvailable else { return }
        // Fire and forget, like the network notifiers: the engine awaits notify()
        // on its actor, and a slow Notification Center must not stall the
        // supervision loop behind a banner.
        let title = notification.title
        let body = notification.body
        let critical = notification.level == .critical
        Task.detached {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if critical {
                content.interruptionLevel = .critical
            }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
