// SPDX-License-Identifier: MIT

import HearthMonitorCore
import Testing
@testable import HearthMonitor

@Suite("Apple Foundation Models adapter")
struct AppleFoundationModelProbeTests {
    actor Operations {
        var calls = 0
        var firstWaiter: CheckedContinuation<Void, Never>?

        func run() async -> AppleModelFunctionalResult {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { firstWaiter = $0 }
            }
            return .completed(0.1)
        }

        func finishFirst() {
            let waiter = firstWaiter
            firstWaiter = nil
            waiter?.resume()
        }

        func count() -> Int { calls }
    }

    @Test("A timed-out request is retained and a second request is not stacked")
    func timeoutContainment() async {
        let operations = Operations()
        let probe = AppleFoundationModelProbe(operation: { await operations.run() })

        let first = await probe.runFunctionalCheck(timeout: 0.01)
        #expect(first == .timedOut)

        let startupClock = ContinuousClock()
        let startupDeadline = startupClock.now.advanced(by: .seconds(1))
        while await operations.count() == 0, startupClock.now < startupDeadline {
            await Task.yield()
        }
        let second = await probe.runFunctionalCheck(timeout: 0.01)
        #expect(second == .requestStillRunning)
        #expect(await operations.count() == 1)

        await operations.finishFirst()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        var third = await probe.runFunctionalCheck(timeout: 0.1)
        while third == .requestStillRunning, clock.now < deadline {
            await Task.yield()
            third = await probe.runFunctionalCheck(timeout: 0.1)
        }
        #expect(third == .completed(0.1))
        #expect(await operations.count() == 2)
    }
}
