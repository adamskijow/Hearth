// SPDX-License-Identifier: MIT

import HearthMonitorCore
import Testing
@testable import HearthMonitor

@Suite("Apple Foundation Models adapter")
struct AppleFoundationModelProbeTests {
    actor Operations {
        var calls = 0

        func run() async -> AppleModelFunctionalResult {
            calls += 1
            if calls == 1 {
                try? await Task.sleep(for: .milliseconds(150))
            }
            return .completed(0.1)
        }

        func count() -> Int { calls }
    }

    @Test("A timed-out request is retained and a second request is not stacked")
    func timeoutContainment() async {
        let operations = Operations()
        let probe = AppleFoundationModelProbe(operation: { await operations.run() })

        let first = await probe.runFunctionalCheck(timeout: 0.01)
        #expect(first == .timedOut)
        let second = await probe.runFunctionalCheck(timeout: 0.01)
        #expect(second == .requestStillRunning)
        #expect(await operations.count() == 1)

        try? await Task.sleep(for: .milliseconds(180))
        let third = await probe.runFunctionalCheck(timeout: 0.1)
        #expect(third == .completed(0.1))
        #expect(await operations.count() == 2)
    }
}
