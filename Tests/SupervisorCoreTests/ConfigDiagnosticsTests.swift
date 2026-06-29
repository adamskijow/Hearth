// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct ConfigDiagnosticsTests {
    private func messages(_ config: HearthConfig) -> [String] {
        ConfigDiagnostics.check(config).map(\.message)
    }
    private func errors(_ config: HearthConfig) -> [Diagnostic] {
        ConfigDiagnostics.check(config).filter { $0.severity == .error }
    }

    @Test func aDefaultConfigIsClean() {
        #expect(ConfigDiagnostics.check(HearthConfig()).isEmpty)
    }

    @Test func portsMustBeInRange() {
        #expect(errors(HearthConfig(port: 0)).contains { $0.message.contains("Runner port 0") })
        #expect(errors(HearthConfig(port: 70000)).contains { $0.message.contains("70000") })
        #expect(messages(HearthConfig(port: 11434)).isEmpty)
    }

    @Test func emptyHostIsAnError() {
        #expect(errors(HearthConfig(host: "   ")).contains { $0.message.contains("Host is empty") })
    }

    @Test func aMalformedHostIsAnError() {
        // A space (or other URL-invalid character) would have crashed the runner's
        // force-unwrapped endpoint; it is now caught here.
        #expect(errors(HearthConfig(host: "127.0.0.1 ")).contains { $0.message.contains("not a valid") })
        #expect(messages(HearthConfig(host: "192.168.1.10")).isEmpty)
    }

    @Test func unknownRunnerAndModeAreErrors() {
        #expect(errors(HearthConfig(runner: "vllm")).contains { $0.message.contains("Unknown runner") })
        #expect(errors(HearthConfig(mode: "supervised")).contains { $0.message.contains("Unknown mode") })
        // The accepted spellings pass.
        #expect(messages(HearthConfig(runner: "lm-studio")).isEmpty)
        #expect(messages(HearthConfig(runner: "mlx_lm")).isEmpty)
    }

    @Test func controlEndpointWithoutATokenIsAnError() {
        let c = HearthConfig(controlEnabled: true, controlToken: nil)
        #expect(errors(c).contains { $0.message.contains("no token") })
        // With a token it is fine (and the control port differs from the runner port).
        let ok = HearthConfig(controlEnabled: true, controlPort: 11455, controlToken: "secret")
        #expect(errors(ok).isEmpty)
    }

    @Test func controlAndRunnerPortsMustDiffer() {
        let c = HearthConfig(port: 11434, controlEnabled: true, controlPort: 11434, controlToken: "secret")
        #expect(errors(c).contains { $0.message.contains("both 11434") })
    }

    @Test func controlChecksAreSkippedWhenDisabled() {
        // No token, colliding port, but control is off: not flagged.
        let c = HearthConfig(controlEnabled: false, controlToken: nil)
        #expect(errors(c).isEmpty)
    }

    @Test func rebootOnWedgeWarnsAboutTheRootRequirement() {
        let issues = ConfigDiagnostics.check(HearthConfig(rebootOnWedge: true))
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("runs as root") })
        // Off by default: no such warning.
        #expect(!ConfigDiagnostics.check(HearthConfig()).contains { $0.message.contains("runs as root") })
    }

    @Test func suspectTimingsAreWarnings() {
        #expect(ConfigDiagnostics.check(HearthConfig(probeIntervalSeconds: 0)).contains {
            $0.severity == .warning && $0.message.contains("Probe interval")
        })
        #expect(ConfigDiagnostics.check(HearthConfig(backoffMultiplier: 0.5)).contains {
            $0.severity == .warning && $0.message.contains("Backoff multiplier")
        })
        #expect(ConfigDiagnostics.check(HearthConfig(initialBackoffSeconds: 10, maxBackoffSeconds: 5)).contains {
            $0.message.contains("Max backoff is less")
        })
    }
}
