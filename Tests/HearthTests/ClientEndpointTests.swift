// SPDX-License-Identifier: MIT

import Foundation
import Testing
import SupervisorCore
@testable import Hearth

private final class CompletionHTTP: HTTPClient, @unchecked Sendable {
    let body: Data
    private let lock = NSLock()
    private var url: URL?
    var postedURL: URL? { lock.withLock { url } }
    init(_ body: String) { self.body = Data(body.utf8) }
    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome { .refused }
    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome {
        lock.withLock { self.url = url }
        return .ok(self.body)
    }
}

struct ClientEndpointTests {
    @Test func manualTestAndCaddyUseTheSelectedClientPath() async throws {
        var config = HearthConfig(host: "127.0.0.1", port: 11434)
        config.metricsProxyEnabled = true
        config.metricsProxyPort = 12436
        let http = CompletionHTTP(#"{"done":true,"eval_count":1}"#)
        _ = try await RunnerProbeSetup.test(config: config, model: "fixture", http: http)
        #expect(http.postedURL?.port == 12436)
        #expect(http.postedURL?.path == "/api/generate")
        #expect(config.clientEndpoint == "http://127.0.0.1:12436")
        let caddy = ProxySetupCLI.caddyfile(bindAddress: "100.64.0.1", proxyPort: 8443,
                                          runnerPort: config.clientPort, token: "fixture")
        #expect(caddy.contains("http://100.64.0.1:8443 {"))
        #expect(caddy.contains("bind 100.64.0.1"))
        #expect(caddy.contains("reverse_proxy 127.0.0.1:12436"))
        config.metricsProxyEnabled = false
        #expect(config.clientPort == 11434)
        config.host = "::"
        #expect(config.clientEndpoint == "http://[::1]:11434")
    }

    @Test func invalidRunnerPortCannotBeHiddenByValidProxyPort() async {
        var config = HearthConfig(host: "runner.example", port: -1)
        config.metricsProxyEnabled = true
        config.metricsProxyPort = 12436
        let http = CompletionHTTP(#"{"done":true,"eval_count":1}"#)
        do {
            _ = try await RunnerProbeSetup.test(config: config, model: "fixture", http: http)
            Issue.record("Invalid runner configuration must not reach a fallback endpoint")
        } catch { }
        #expect(http.postedURL == nil)
    }

    @Test func manualTestRejectsAnEmptyHTTP200() async {
        do {
            _ = try await RunnerProbeSetup.test(config: HearthConfig(), model: "fixture", http: CompletionHTTP("{}"))
            Issue.record("An empty HTTP success cannot verify inference")
        } catch { }
    }
}
