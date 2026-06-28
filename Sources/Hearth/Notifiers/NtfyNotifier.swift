// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Posts notifications to an ntfy topic over HTTP, so a headless Mac with no one
/// sitting at it can still reach a phone. The user sets a topic; subscribing on
/// the phone is out of band (the ntfy app or a self hosted server).
///
/// ntfy only ever receives a short title and body describing a supervision
/// transition. No runner content, prompts, or model data is sent.
final class NtfyNotifier: Notifier, @unchecked Sendable {
    private let server: String
    private let topic: String
    private let session: URLSession

    init(server: String, topic: String) {
        // Trim a trailing slash so "https://ntfy.sh/" and "https://ntfy.sh" behave.
        self.server = server.hasSuffix("/") ? String(server.dropLast()) : server
        self.topic = topic
        self.session = URLSession(configuration: .ephemeral)
    }

    func notify(_ notification: HearthNotification) async {
        guard let url = URL(string: "\(server)/\(topic)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(notification.body.utf8)
        request.setValue(notification.title, forHTTPHeaderField: "Title")
        request.setValue(Self.priority(for: notification.level), forHTTPHeaderField: "Priority")
        request.setValue(Self.tags(for: notification.level), forHTTPHeaderField: "Tags")
        _ = try? await session.data(for: request)
    }

    private static func priority(for level: NotificationLevel) -> String {
        switch level {
        case .info: return "default"
        case .warning: return "high"
        case .critical: return "urgent"
        }
    }

    private static func tags(for level: NotificationLevel) -> String {
        switch level {
        case .info: return "white_check_mark"
        case .warning: return "warning"
        case .critical: return "rotating_light"
        }
    }
}
