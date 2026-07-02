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

    @Test func logTailIsAppendedOnlyWhereOptedInAndOnlyToFailureAlerts() throws {
        let tail = ["ggml_metal: failed to allocate buffer", "llama runner exited"]
        let down = try #require(SupervisorEngine.notification(for: .down(.crashed(.outOfMemory)), logTail: tail))
        #expect(down.body.contains("Runner log tail (alertsIncludeLogTail):"))
        #expect(down.body.contains("failed to allocate buffer"))
        let failing = try #require(SupervisorEngine.notification(
            for: .enteredFailing(restartsInWindow: 5, window: 60), logTail: tail))
        #expect(failing.body.contains("llama runner exited"))
        // The all-clear never carries log content, opted in or not.
        let recovered = try #require(SupervisorEngine.notification(for: .recovered, logTail: tail))
        #expect(!recovered.body.contains("log tail"))
        // Without the opt-in (the default), nothing changes.
        let quiet = try #require(SupervisorEngine.notification(for: .down(.wedged)))
        #expect(!quiet.body.contains("log tail"))
    }

    @Test func logTailIsBoundedAndStripped() {
        let noisy = (1...20).map { "line \($0)" } + [String(repeating: "x", count: 500) + "\u{1B}[31mred\u{07}"]
        let tail = SupervisorEngine.sanitizedLogTail(noisy)
        #expect(tail.count == 5)
        #expect(tail.last?.count ?? 0 <= 201)   // 200 plus the ellipsis
        #expect(!(tail.last?.contains("\u{1B}") ?? true))
        #expect(!(tail.last?.contains("\u{07}") ?? true))
    }

    @Test func aFailedWarmupWarnsAndACleanOneIsQuiet() throws {
        let failed = try #require(SupervisorEngine.notification(for: .warmupFinished(missing: ["llama3:8b"])))
        #expect(failed.level == .warning)
        #expect(failed.body.contains("llama3:8b"))
        #expect(SupervisorEvent.warmupFinished(missing: ["llama3:8b"]).isNotable)
        // A warm-up that restored everything is routine: logged, never pushed.
        #expect(SupervisorEngine.notification(for: .warmupFinished(missing: [])) == nil)
        #expect(!SupervisorEvent.warmupFinished(missing: []).isNotable)
    }
}
