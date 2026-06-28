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

    func notify(_ notification: HearthNotification) async {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        if notification.level == .critical {
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
