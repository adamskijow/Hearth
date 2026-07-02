// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Posts notifications to an ntfy topic over HTTP, so a headless Mac with no one
/// sitting at it can still reach a phone. The user sets a topic; subscribing on
/// the phone is out of band (the ntfy app or a self hosted server).
///
/// ntfy only ever receives a short title and body describing a supervision
/// transition. No runner content, prompts, or model data is sent, unless the
/// user opted into alertsIncludeLogTail, which appends a bounded runner log
/// tail to down and failing bodies (the doctor warns when that rides the
/// public ntfy.sh).
final class NtfyNotifier: Notifier, @unchecked Sendable {
    private let server: String
    private let topic: String
    private let session: URLSession

    init(server: String, topic: String) {
        // Trim a trailing slash so "https://ntfy.sh/" and "https://ntfy.sh" behave.
        self.server = server.hasSuffix("/") ? String(server.dropLast()) : server
        self.topic = topic
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration)
    }

    /// The characters allowed through unencoded in the topic path segment.
    /// Deliberately stricter than `.urlPathAllowed`, which passes `/` (and `..`)
    /// through: a topic with a slash would otherwise become extra path segments
    /// and post to a different endpoint than the one the user subscribed to.
    private static let topicAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    func notify(_ notification: HearthNotification) async {
        // Percent-encode the topic so a topic with a space, slash, or other
        // URL-significant character stays one path segment instead of silently
        // producing a nil URL or posting somewhere else.
        let encodedTopic = topic.addingPercentEncoding(withAllowedCharacters: Self.topicAllowed) ?? topic
        guard let url = URL(string: "\(server)/\(encodedTopic)") else {
            // A malformed server URL would otherwise silently eat every alert the
            // user believes they configured.
            FileHandle.standardError.write(
                Data("Hearth: ntfy alert dropped: \"\(server)/\(encodedTopic)\" is not a valid URL; check ntfyServer in the config\n".utf8))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = Data(notification.body.utf8)
        request.setValue(notification.title, forHTTPHeaderField: "Title")
        request.setValue(Self.priority(for: notification.level), forHTTPHeaderField: "Priority")
        request.setValue(Self.tags(for: notification.level), forHTTPHeaderField: "Tags")
        // Fire and forget. The engine awaits notify() on its actor, which also
        // serves status, control commands, and state publishing; blocking it on a
        // slow or hung ntfy server (up to the request timeout) would stall the
        // whole supervision loop. Delivery happens in the background instead,
        // but a failure is still one stderr line: on a headless Mac ntfy is
        // often the only channel to a human, and a wrong server or 401 silently
        // eating critical alerts is worse than a noisy log. The topic (a bearer
        // secret) is never printed.
        let session = self.session
        let server = self.server
        Task.detached {
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    FileHandle.standardError.write(Data(
                        "Hearth: ntfy alert to \(server) failed: HTTP \(http.statusCode)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "Hearth: ntfy alert to \(server) failed: \(error.localizedDescription)\n".utf8))
            }
        }
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
