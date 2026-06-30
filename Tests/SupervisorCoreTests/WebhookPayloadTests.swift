// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct WebhookPayloadTests {
    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func includesLevelTitleBodyEventAndTimestamp() {
        let note = HearthNotification(level: .warning, title: "Hearth: down", body: "the runner stopped", event: .down(.wedged))
        let json = object(WebhookPayload.json(for: note, timestamp: "2026-06-30T00:00:00Z"))
        #expect(json["level"] as? String == "warning")
        #expect(json["title"] as? String == "Hearth: down")
        #expect(json["body"] as? String == "the runner stopped")
        #expect(json["event"] as? String == "down")
        #expect(json["timestamp"] as? String == "2026-06-30T00:00:00Z")
    }

    @Test func omitsEventWhenThereIsNone() {
        // A pressure alert has no originating event.
        let note = HearthNotification(level: .info, title: "Hearth: memory eased", body: "back to 70%")
        let json = object(WebhookPayload.json(for: note, timestamp: "t"))
        #expect(json["event"] == nil)
        #expect(json["level"] as? String == "info")
    }

    @Test func mapsEveryEventToAStableKind() {
        let events: [SupervisorEvent] = [
            .started, .becameHealthy, .down(.wedged), .restartScheduled(attempt: 1, backoff: 1),
            .restarted(attempt: 1), .maintenanceRestart, .recovered,
            .enteredFailing(restartsInWindow: 5, window: 60), .modelsUpdated([]), .stopped,
        ]
        let kinds = events.map(WebhookPayload.eventKind)
        // All present, all distinct, all snake_case (no spaces or capitals).
        #expect(Set(kinds).count == events.count)
        #expect(kinds.allSatisfy { !$0.contains(" ") && $0 == $0.lowercased() })
    }
}
