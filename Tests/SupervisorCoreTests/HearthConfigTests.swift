// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The config is data driven and decoded leniently. These pin the decoding
/// behavior, the per key fallback to defaults, and the mapping onto the policy
/// and the runner.
struct HearthConfigTests {
    @Test func decodesAFullConfig() throws {
        let json = Data("""
        {
          "ollamaBinaryPath": "/custom/ollama",
          "host": "10.0.0.5",
          "port": 9000,
          "probeTimeoutSeconds": 4,
          "probeIntervalSeconds": 6,
          "startupGraceSeconds": 20,
          "startupProbeIntervalSeconds": 2,
          "initialBackoffSeconds": 3,
          "backoffMultiplier": 1.5,
          "maxBackoffSeconds": 45,
          "crashLoopThreshold": 7,
          "crashLoopWindowSeconds": 90,
          "failingProbeIntervalSeconds": 25,
          "ntfyTopic": "abc",
          "ntfyServer": "https://example.org",
          "localNotifications": false
        }
        """.utf8)
        let config = try JSONDecoder().decode(HearthConfig.self, from: json)
        #expect(config.ollamaBinaryPath == "/custom/ollama")
        #expect(config.host == "10.0.0.5")
        #expect(config.port == 9000)
        #expect(config.backoffMultiplier == 1.5)
        #expect(config.crashLoopThreshold == 7)
        #expect(config.ntfyTopic == "abc")
        #expect(config.ntfyServer == "https://example.org")
        #expect(config.localNotifications == false)
    }

    @Test func emptyObjectUsesAllDefaults() throws {
        let config = try JSONDecoder().decode(HearthConfig.self, from: Data("{}".utf8))
        #expect(config == HearthConfig())
    }

    @Test func partialConfigFallsBackPerKey() throws {
        let json = Data(#"{"port": 9999, "probeIntervalSeconds": 3}"#.utf8)
        let config = try JSONDecoder().decode(HearthConfig.self, from: json)
        // Present keys take effect.
        #expect(config.port == 9999)
        #expect(config.probeIntervalSeconds == 3)
        // Missing keys fall back to the documented defaults.
        #expect(config.host == "127.0.0.1")
        #expect(config.maxBackoffSeconds == 60)
        #expect(config.localNotifications == true)
    }

    @Test func ntfyTopicDefaultsToNil() {
        #expect(HearthConfig().ntfyTopic == nil)
    }

    @Test func policyMapsEveryTimingKnob() {
        let json = HearthConfig(
            probeTimeoutSeconds: 4,
            probeIntervalSeconds: 6,
            startupGraceSeconds: 20,
            startupProbeIntervalSeconds: 2,
            initialBackoffSeconds: 3,
            backoffMultiplier: 1.5,
            maxBackoffSeconds: 45,
            crashLoopThreshold: 7,
            crashLoopWindowSeconds: 90,
            failingProbeIntervalSeconds: 25
        )
        let policy = json.policy()
        #expect(policy.probeTimeout == 4)
        #expect(policy.probeInterval == 6)
        #expect(policy.startupGrace == 20)
        #expect(policy.startupProbeInterval == 2)
        #expect(policy.initialBackoff == 3)
        #expect(policy.backoffMultiplier == 1.5)
        #expect(policy.maxBackoff == 45)
        #expect(policy.crashLoopThreshold == 7)
        #expect(policy.crashLoopWindow == 90)
        #expect(policy.failingProbeInterval == 25)
    }

    @Test func runnerCarriesHostAndPort() {
        let config = HearthConfig(ollamaBinaryPath: "/x", host: "0.0.0.0", port: 1234)
        let runner = config.makeOllamaRunner()
        // The wildcard host still binds every interface, but it is not a
        // connectable destination, so the probe URL dials loopback instead.
        #expect(runner.readinessEndpoint.absoluteString == "http://127.0.0.1:1234/api/version")
        #expect(runner.processSpec().environmentOverrides["OLLAMA_HOST"] == "0.0.0.0:1234")
    }

    @Test func runnerSelectionDefaultsToOllama() {
        let runner = HearthConfig().makeRunner()
        #expect(runner.name == "Ollama")
    }

    @Test func setSelectedBinaryPathWritesTheRunnersOwnField() {
        // One setter so the first-run template and `hearth setup` cannot disagree.
        var lm = HearthConfig(runner: "lmstudio")
        lm.setSelectedBinaryPath("/x/lms")
        #expect(lm.lmStudioBinaryPath == "/x/lms")
        #expect(lm.selectedBinaryPath == "/x/lms")
        var mlx = HearthConfig(runner: "mlx")
        mlx.setSelectedBinaryPath("/x/mlx")
        #expect(mlx.mlxBinaryPath == "/x/mlx")
        var ollama = HearthConfig()
        ollama.setSelectedBinaryPath("/x/ollama")
        #expect(ollama.ollamaBinaryPath == "/x/ollama")
    }

    @Test func runnerEnvDecodesAndReachesTheRunner() throws {
        let json = Data("""
        {"runnerEnv": {"OLLAMA_LOAD_TIMEOUT": "10m", "OLLAMA_KEEP_ALIVE": "30m"}}
        """.utf8)
        let config = try JSONDecoder().decode(HearthConfig.self, from: json)
        #expect(config.runnerEnv["OLLAMA_LOAD_TIMEOUT"] == "10m")
        // It flows through to the spawned runner's environment.
        let env = config.makeOllamaRunner().processSpec().environmentOverrides
        #expect(env["OLLAMA_LOAD_TIMEOUT"] == "10m")
        #expect(env["OLLAMA_KEEP_ALIVE"] == "30m")
    }

    @Test func runnerEnvDefaultsToEmpty() throws {
        let config = try JSONDecoder().decode(HearthConfig.self, from: Data("{}".utf8))
        #expect(config.runnerEnv.isEmpty)
    }

    @Test func runnerSelectionPicksLMStudio() {
        let config = HearthConfig(runner: "lmstudio")
        #expect(config.makeRunner().name == "LM Studio")
        #expect(config.selectedBinaryPath == HearthConfig.defaultLMStudioBinaryPath)
    }

    @Test func modeControlsIsManaged() {
        #expect(HearthConfig().isManaged)                    // default managed
        #expect(HearthConfig(mode: "managed").isManaged)
        #expect(!HearthConfig(mode: "attached").isManaged)
    }

    @Test func runnerUserNormalizationTrimsWhitespaceAndBlanks() throws {
        #expect(HearthConfig(runnerUser: " joseph \n").normalizedRunnerUser == "joseph")
        #expect(HearthConfig(runnerUser: "   ").normalizedRunnerUser == nil)

        let decoded = try JSONDecoder().decode(HearthConfig.self, from: Data(#"{"runnerUser":" daemon "}"#.utf8))
        #expect(decoded.normalizedRunnerUser == "daemon")
    }

    @Test func controlFieldsDecode() throws {
        let json = Data("""
        {"controlEnabled": true, "controlHost": "100.64.0.2", "controlPort": 8443, "controlToken": "abc123"}
        """.utf8)
        let config = try JSONDecoder().decode(HearthConfig.self, from: json)
        #expect(config.controlEnabled == true)
        #expect(config.controlHost == "100.64.0.2")
        #expect(config.controlPort == 8443)
        #expect(config.controlToken == "abc123")
    }

    @Test func controlDefaultsAreClosed() {
        let config = HearthConfig()
        #expect(config.controlEnabled == false)
        #expect(config.controlToken == nil)
    }
}
