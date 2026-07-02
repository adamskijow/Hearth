// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The fourth runner, exercised the same way the seam was proven for the others:
/// everything Osaurus specific stays inside OsaurusRunner.
struct OsaurusRunnerTests {
    private let runner = OsaurusRunner(binaryPath: "/Applications/Osaurus.app/Contents/MacOS/osaurus")

    @Test func launchesServeOnTheConfiguredPort() {
        let spec = OsaurusRunner(binaryPath: "/x/osaurus", port: 4242).processSpec()
        #expect(spec.executableURL.path == "/x/osaurus")
        #expect(spec.arguments == ["serve", "--port", "4242"])
    }

    @Test func probesTheOpenAIModelsEndpointOnItsDefaultPort() {
        #expect(runner.readinessEndpoint.absoluteString == "http://127.0.0.1:1337/v1/models")
        #expect(runner.modelsEndpoint.absoluteString == "http://127.0.0.1:1337/v1/models")
    }

    @Test func parsesTheOpenAIModelList() throws {
        let body = #"{"object":"list","data":[{"id":"llama-3.2-3b"},{"id":"qwen2.5-0.5b"}]}"#
        let models = try runner.parseResidentModels(Data(body.utf8))
        #expect(models.map(\.name) == ["llama-3.2-3b", "qwen2.5-0.5b"])
    }

    @Test func deepProbeIsAOneTokenChatCompletion() throws {
        let request = try #require(runner.deepReadinessRequest(model: "llama-3.2-3b"))
        #expect(request.url.absoluteString == "http://127.0.0.1:1337/v1/chat/completions")
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains(#""model":"llama-3.2-3b""#) || body.contains(#""model" : "llama-3.2-3b""#))
    }

    @Test func kindMapsAndCarriesTheVocabulary() {
        #expect(RunnerKind(fromConfigString: "osaurus") == .osaurus)
        #expect(RunnerKind(fromConfigString: "Osaurus") == .osaurus)
        #expect(RunnerKind.osaurus.displayName == "Osaurus")
        #expect(RunnerKind.osaurus.installHint == "brew install --cask osaurus")
        #expect(HearthConfig(runner: "osaurus").runnerKind == .osaurus)
    }

    @Test func doctorRecommendsAttachedAndTheRightPort() {
        let managed = HearthConfig(runner: "osaurus", mode: "managed")
        #expect(ConfigDiagnostics.check(managed).contains { $0.message.contains("osaurus serve") })
        // Default port 11434 with Osaurus selected draws the port hint.
        #expect(ConfigDiagnostics.check(managed).contains { $0.message.contains("1337") })
        let attached = HearthConfig(runner: "osaurus", mode: "attached", port: 1337)
        #expect(!ConfigDiagnostics.check(attached).contains { $0.message.contains("osaurus serve") })
    }
}
