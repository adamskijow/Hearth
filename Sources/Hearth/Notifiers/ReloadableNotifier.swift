// SPDX-License-Identifier: MIT

import SupervisorCore

/// A stable notifier reference held by the engine whose delivery channels can be
/// replaced on a live config reload. The actor makes replacement atomic with
/// respect to notification delivery without blocking the supervision actor.
actor ReloadableNotifier: Notifier {
    private var wrapped: any Notifier

    init(_ wrapped: any Notifier) {
        self.wrapped = wrapped
    }

    func replace(with notifier: any Notifier) {
        wrapped = notifier
    }

    func notify(_ notification: HearthNotification) async {
        await wrapped.notify(notification)
    }
}
