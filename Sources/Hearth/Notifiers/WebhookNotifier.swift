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
        // endpoint must not block the supervision loop), but a failure is one
        // stderr line so a misconfigured webhook (401, 500, unreachable) does not
        // fail invisibly. Only the host is printed; the path may carry a secret.
        let session = self.session
        let host = url.host ?? "webhook"
        Task.detached {
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    FileHandle.standardError.write(Data(
                        "Hearth: webhook alert to \(host) failed: HTTP \(http.statusCode)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "Hearth: webhook alert to \(host) failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
