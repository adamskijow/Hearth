// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct HealthTests {
    @Test func readinessMapsEveryHTTPOutcome() {
        #expect(Readiness.from(.ok(Data())) == .ready)
        #expect(Readiness.from(.http(status: 503, body: Data())) == .notReady)
        #expect(Readiness.from(.timedOut) == .timedOut)        // alive but wedged
        #expect(Readiness.from(.refused) == .notReady)
        #expect(Readiness.from(.failure("boom")) == .notReady)
    }

    @Test func servingRequiresAliveAndReady() {
        #expect(HealthReport(isAlive: true, readiness: .ready).isServing)
        // Alive but wedged or not answering is not serving: the case a plain PID
        // check would wrongly call healthy.
        #expect(!HealthReport(isAlive: true, readiness: .timedOut).isServing)
        #expect(!HealthReport(isAlive: true, readiness: .notReady).isServing)
        // Dead is never serving, even if a stale listener answers.
        #expect(!HealthReport(isAlive: false, readiness: .ready).isServing)
        #expect(!HealthReport(isAlive: false, readiness: .unknown).isServing)
    }
}
