// SPDX-License-Identifier: MIT

import Foundation

/// Severity of a notification, mapped by implementations onto their own
/// priority schemes (ntfy priority, notification interruption level).
public enum NotificationLevel: Sendable, Equatable {
    case info
    case warning
    case critical
}

/// A notification the supervisor wants delivered. Carries the originating event
/// so a smart notifier could route on it.
public struct HearthNotification: Sendable, Equatable {
    public var level: NotificationLevel
    public var title: String
    public var body: String
    /// The supervisor event that triggered this, when there is one. Nil for
    /// notifications not tied to a state transition, such as a memory or thermal
    /// pressure alert.
    public var event: SupervisorEvent?

    public init(level: NotificationLevel, title: String, body: String, event: SupervisorEvent? = nil) {
        self.level = level
        self.title = title
        self.body = body
        self.event = event
    }
}

/// Delivery behind a protocol. The deployed app provides an ntfy implementation
/// (so a headless Mac can reach a phone) and a local implementation (for when
/// you are at the machine). Tests provide a recorder. The decision of *when* to
/// notify lives in the engine, so it is tested without sending anything.
public protocol Notifier: Sendable {
    func notify(_ notification: HearthNotification) async
}

/// Fan a single notification out to several notifiers.
public struct CompositeNotifier: Notifier {
    private let notifiers: [Notifier]

    public init(_ notifiers: [Notifier]) {
        self.notifiers = notifiers
    }

    public func notify(_ notification: HearthNotification) async {
        for notifier in notifiers {
            await notifier.notify(notification)
        }
    }
}
