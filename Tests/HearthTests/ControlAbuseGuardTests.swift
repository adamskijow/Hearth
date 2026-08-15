// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Hearth

struct ControlAbuseGuardTests {
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
    }

    @Test func repeatedFailuresTemporarilyLockOnlyThatPeer() {
        let clock = Clock()
        let guardrail = ControlAbuseGuard(
            maximumFailures: 3, window: 60, now: { clock.now() })

        for _ in 0..<2 { guardrail.recordFailure(peer: "phone") }
        #expect(!guardrail.shouldReject(peer: "phone"))
        guardrail.recordFailure(peer: "phone")
        #expect(guardrail.shouldReject(peer: "phone"))
        #expect(!guardrail.shouldReject(peer: "laptop"))

        clock.advance(61)
        #expect(!guardrail.shouldReject(peer: "phone"))
    }

    @Test func successfulAuthenticationClearsFailureHistory() {
        let guardrail = ControlAbuseGuard(maximumFailures: 2, window: 60)
        guardrail.recordFailure(peer: "phone")
        guardrail.recordSuccess(peer: "phone")
        guardrail.recordFailure(peer: "phone")
        #expect(!guardrail.shouldReject(peer: "phone"))
    }

    @Test func browserResponsesCannotBeFramedOrPersisted() {
        let headers = Dictionary(uniqueKeysWithValues: ControlResponseSecurity.headers)
        #expect(headers["X-Frame-Options"] == "DENY")
        #expect(headers["Cache-Control"] == "no-store")
        #expect(headers["Content-Security-Policy"]?.contains("frame-ancestors 'none'") == true)
        #expect(headers["X-Content-Type-Options"] == "nosniff")
    }

    @Test func connectionBudgetRefusesOverflowAndRecoversSlots() {
        var budget = ControlConnectionBudget(limit: 2)
        let first = UUID(), second = UUID(), third = UUID()
        let admittedFirst = budget.admit(first)
        let admittedSecond = budget.admit(second)
        let admittedOverflow = budget.admit(third)
        #expect(admittedFirst)
        #expect(admittedSecond)
        #expect(!admittedOverflow)
        #expect(budget.count == 2)
        budget.release(first)
        let admittedAfterRelease = budget.admit(third)
        #expect(admittedAfterRelease)
        budget.releaseAll()
        #expect(budget.count == 0)
    }
}
