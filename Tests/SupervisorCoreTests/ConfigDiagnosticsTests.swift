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

    @Test func runnerEnvOllamaHostIsWarned() {
        // Hearth owns OLLAMA_HOST (from host/port), so setting it in runnerEnv is a
        // no-op worth flagging. Other runnerEnv keys are fine.
        #expect(messages(HearthConfig(runnerEnv: ["OLLAMA_HOST": "0.0.0.0:11434"]))
                .contains { $0.contains("runnerEnv sets OLLAMA_HOST") })
        #expect(messages(HearthConfig(runnerEnv: ["OLLAMA_LOAD_TIMEOUT": "10m"])).isEmpty)
    }

    @Test func exposedControlAndWeakSecretsAreWarned() {
        let strong = "a-long-enough-unguessable-secret"
        #expect(messages(HearthConfig(host: "0.0.0.0"))
                .contains { $0.contains("Runner is bound to 0.0.0.0") })
        #expect(messages(HearthConfig(host: "::"))
                .contains { $0.contains("Runner is bound to ::") })
        // 0.0.0.0 control bind exposes the start/stop/restart surface.
        #expect(messages(HearthConfig(controlEnabled: true, controlHost: "0.0.0.0", controlToken: strong))
                .contains { $0.contains("all interfaces") })
        #expect(!messages(HearthConfig(controlEnabled: true, controlHost: "127.0.0.1", controlToken: strong))
                .contains { $0.contains("all interfaces") })
        // Placeholder or short control token.
        #expect(messages(HearthConfig(controlEnabled: true, controlToken: "CHANGE-ME-to-a-long-random-secret"))
                .contains { $0.contains("placeholder or shorter") })
        #expect(messages(HearthConfig(controlEnabled: true, controlToken: "short"))
                .contains { $0.contains("placeholder or shorter") })
        // Placeholder ntfy topic would post to a guessable public topic.
        #expect(messages(HearthConfig(ntfyTopic: "CHANGE-ME-to-a-long-random-string"))
                .contains { $0.contains("ntfyTopic is still the placeholder") })
        #expect(messages(HearthConfig(ntfyTopic: "short"))
                .contains { $0.contains("shorter than 16") })
        #expect(messages(HearthConfig(webhookURL: "http://example.test/hook"))
                .contains { $0.contains("does not use HTTPS") })
    }

    @Test func ipv6LiteralHostsAreNotErrors() {
        // Bare IPv6 literals are bracketed before URL validation, the same way
        // the probe endpoints dial them, so a host supervision handles fine is
        // not flagged as an invalid address.
        #expect(errors(HearthConfig(host: "::1")).isEmpty)
        #expect(errors(HearthConfig(host: "fe80::1")).isEmpty)
        // The wildcard :: keeps its all-interfaces warning but is not an error.
        #expect(errors(HearthConfig(host: "::")).isEmpty)
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
        // The accepted spellings are recognized (no unknown-runner error). LM
        // Studio uses attached mode here to avoid the managed-mode warning.
        #expect(!errors(HearthConfig(runner: "lm-studio", mode: "attached")).contains { $0.message.contains("Unknown runner") })
        #expect(!errors(HearthConfig(runner: "mlx_lm", port: 8080)).contains { $0.message.contains("Unknown runner") })
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

    @Test func lmStudioManagedWarnsToUseAttached() {
        let managed = ConfigDiagnostics.check(HearthConfig(runner: "lmstudio", mode: "managed"))
        #expect(managed.contains { $0.severity == .warning && $0.message.contains("attached mode") })
        // Attached LM Studio, and managed Ollama, are fine.
        #expect(!ConfigDiagnostics.check(HearthConfig(runner: "lmstudio", mode: "attached")).contains { $0.message.contains("attached mode") })
        #expect(!ConfigDiagnostics.check(HearthConfig(runner: "ollama", mode: "managed")).contains { $0.message.contains("attached mode") })
    }

    @Test func runnerSpecificDefaultPortsAreWarned() {
        #expect(messages(HearthConfig(runner: "lmstudio", mode: "attached", port: 11434))
                .contains { $0.contains("usually serves on port 1234") })
        #expect(!messages(HearthConfig(runner: "lmstudio", mode: "attached", port: 1234))
                .contains { $0.contains("usually serves on port 1234") })
        #expect(messages(HearthConfig(runner: "mlx", port: 11434))
                .contains { $0.contains("usually serves on port 8080") })
        #expect(!messages(HearthConfig(runner: "mlx", port: 8080))
                .contains { $0.contains("usually serves on port 8080") })
    }

    @Test func rebootOnWedgeWarnsAboutTheRootRequirement() {
        let issues = ConfigDiagnostics.check(HearthConfig(rebootOnWedge: true))
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("runs as root") })
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("requires runnerUser") })
        #expect(!ConfigDiagnostics.check(HearthConfig(rebootOnWedge: true, runnerUser: "daemon"), runningAsRoot: true)
                .contains { $0.message.contains("runs as root") })
        // Off by default: no such warning.
        #expect(!ConfigDiagnostics.check(HearthConfig()).contains { $0.message.contains("runs as root") })
    }

    @Test func rootRunnerUserIsAnError() {
        let issues = ConfigDiagnostics.check(HearthConfig(runnerUser: "root"), runningAsRoot: true)
        #expect(issues.contains { $0.severity == .error && $0.message.contains("runnerUser resolves to root") })
    }

    @Test func unresolvedRunnerUserIsAnError() {
        let issues = ConfigDiagnostics.check(HearthConfig(runnerUser: "no_such_hearth_account_zzzz"), runningAsRoot: true)
        #expect(issues.contains { $0.severity == .error && $0.message.contains("does not resolve") })
    }

    @Test func rootManagedModeWithoutRunnerUserWarns() {
        let issues = ConfigDiagnostics.check(HearthConfig(mode: "managed"), runningAsRoot: true)
        #expect(issues.contains { $0.severity == .error && $0.message.contains("refuses to start") })
        #expect(!ConfigDiagnostics.check(HearthConfig(mode: "attached"), runningAsRoot: true)
                .contains { $0.message.contains("refuses to start") })
        #expect(!ConfigDiagnostics.check(HearthConfig(mode: "managed"), runningAsRoot: false)
                .contains { $0.message.contains("refuses to start") })
    }

    @Test func runnerUserIsOnlyValidatedForManagedRootDaemonMode() {
        #expect(!ConfigDiagnostics.check(HearthConfig(mode: "attached", runnerUser: "root"), runningAsRoot: true)
                .contains { $0.message.contains("runnerUser resolves to root") })
        #expect(!ConfigDiagnostics.check(HearthConfig(mode: "attached", runnerUser: "no_such_hearth_account_zzzz"), runningAsRoot: true)
                .contains { $0.message.contains("does not resolve") })
        #expect(!ConfigDiagnostics.check(HearthConfig(mode: "managed", runnerUser: "no_such_hearth_account_zzzz"))
                .contains { $0.message.contains("does not resolve") })
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
