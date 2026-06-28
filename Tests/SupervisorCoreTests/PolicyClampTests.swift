// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

/// Config values that would brick supervision are clamped to a safe floor when
/// mapped to the restart policy, independent of the diagnostics warnings.
struct PolicyClampTests {
    @Test func policyClampsBrickingValues() {
        let policy = HearthConfig(
            probeIntervalSeconds: 0,
            startupProbeIntervalSeconds: -5,
            backoffMultiplier: 0.5,
            crashLoopThreshold: 0,
            failingProbeIntervalSeconds: 0
        ).policy()

        #expect(policy.probeInterval >= 0.1)        // no busy spin
        #expect(policy.startupProbeInterval >= 0.1)
        #expect(policy.backoffMultiplier >= 1)      // backoff cannot shrink
        #expect(policy.crashLoopThreshold >= 1)     // does not trip on the first failure
        #expect(policy.failingProbeInterval >= 0.1)
    }

    @Test func validValuesPassThroughUnchanged() {
        let policy = HearthConfig(
            probeIntervalSeconds: 5,
            backoffMultiplier: 2,
            crashLoopThreshold: 3
        ).policy()
        #expect(policy.probeInterval == 5)
        #expect(policy.backoffMultiplier == 2)
        #expect(policy.crashLoopThreshold == 3)
    }

    @Test func runnerEndpointsNeverTrapOnABadHost() {
        // A host with a space made URL(string:)! crash; now it yields an
        // unconnectable URL instead of trapping the supervisor.
        let runner = OllamaRunner(binaryPath: "/x", host: "bad host", port: 11434)
        _ = runner.readinessEndpoint
        _ = runner.modelsEndpoint
        let fallback = runnerEndpoint(host: "bad host", port: -1, path: "/api/version")
        #expect(fallback.path == "/api/version")
    }
}
