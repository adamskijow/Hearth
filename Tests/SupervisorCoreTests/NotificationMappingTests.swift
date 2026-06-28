// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The engine turns notable events into notifications at the right severity, and
/// produces nothing for the rest. Notifications fire on down, recovered, and
/// failing.
struct NotificationMappingTests {
    @Test func downIsAWarning() throws {
        let notification = try #require(SupervisorEngine.notification(for: .down(.wedged)))
        #expect(notification.level == .warning)
    }

    @Test func crashedDownCarriesTheReason() throws {
        let notification = try #require(SupervisorEngine.notification(for: .down(.crashed(.outOfMemory))))
        #expect(notification.level == .warning)
        #expect(notification.body.contains("out of memory"))
    }

    @Test func recoveredIsInfo() throws {
        let notification = try #require(SupervisorEngine.notification(for: .recovered))
        #expect(notification.level == .info)
    }

    @Test func failingIsCritical() throws {
        let notification = try #require(
            SupervisorEngine.notification(for: .enteredFailing(restartsInWindow: 5, window: 60))
        )
        #expect(notification.level == .critical)
    }

    @Test func nonNotableEventsProduceNoNotification() {
        #expect(SupervisorEngine.notification(for: .becameHealthy) == nil)
        #expect(SupervisorEngine.notification(for: .started) == nil)
        #expect(SupervisorEngine.notification(for: .restarted(attempt: 1)) == nil)
        #expect(SupervisorEngine.notification(for: .stopped) == nil)
    }

    @Test func notableEventsAreFlaggedNotable() {
        #expect(SupervisorEvent.down(.wedged).isNotable)
        #expect(SupervisorEvent.recovered.isNotable)
        #expect(SupervisorEvent.enteredFailing(restartsInWindow: 1, window: 1).isNotable)
        #expect(!SupervisorEvent.becameHealthy.isNotable)
    }
}
