// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// POSTs a small JSON body to a configured webhook URL on each supervision
/// notification, so Hearth can be wired into your own automation alongside (or
/// instead of) ntfy. Fire and forget, like the ntfy notifier; the body carries
/// only Hearth's own short status, never runner content.
final class WebhookNotifier: Notifier, @unchecked Sendable {
    private let url: URL
    private let session: URLSession

    init(url: URL) {
        self.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration)
    }

    func notify(_ notification: HearthNotification) async {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = WebhookPayload.json(for: notification, timestamp: timestamp)
        // Fire and forget, off the engine's actor (see NtfyNotifier for why a slow
        // endpoint must not block the supervision loop).
        let session = self.session
        Task.detached { _ = try? await session.data(for: request) }
    }
}
