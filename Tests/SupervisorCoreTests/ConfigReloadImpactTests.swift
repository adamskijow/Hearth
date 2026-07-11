// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct ConfigReloadImpactTests {
    @Test func identicalConfigDoesNothing() {
        let config = HearthConfig()
        #expect(ConfigReloadImpact.between(config, config) == .none)
    }

    @Test func surroundingServicesReloadWithoutRestartingTheRunner() {
        let original = HearthConfig()
        var changed = original
        changed.notificationsPaused = true
        changed.ntfyTopic = "hearth-phone"
        changed.memoryAlertPercent = 85
        changed.heartbeatURL = "https://example.test/pulse"
        changed.controlEnabled = true
        changed.controlToken = "a-long-random-control-token"
        changed.controlTokens = ["phone": "another-long-random-token"]
        changed.controlStatusTokens = ["hearth-monitor": "read-only-long-random-token"]
        #expect(ConfigReloadImpact.between(original, changed) == .live)
    }

    @Test func runnerAndEngineSettingsRemainRestartBoundaries() {
        let original = HearthConfig()

        var port = original
        port.port = 4242
        #expect(ConfigReloadImpact.between(original, port) == .restart)

        var probe = original
        probe.probeModel = "qwen2.5:0.5b"
        #expect(ConfigReloadImpact.between(original, probe) == .restart)

        var logging = original
        logging.logMaxBytes += 1
        #expect(ConfigReloadImpact.between(original, logging) == .restart)
    }

    @Test func aLiveAndRestartChangeTogetherRequiresRestart() {
        let original = HearthConfig()
        var changed = original
        changed.notificationsPaused = true
        changed.runnerEnv["OLLAMA_KEEP_ALIVE"] = "30m"
        #expect(ConfigReloadImpact.between(original, changed) == .restart)
    }
}
