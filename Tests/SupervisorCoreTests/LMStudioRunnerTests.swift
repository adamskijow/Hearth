// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The second runner proves the protocol extends without touching the engine.
/// These cover its LM Studio specific spec, endpoints, and model parsing.
struct LMStudioRunnerTests {
    @Test func processSpecLaunchesTheServer() {
        let runner = LMStudioRunner(binaryPath: "/usr/local/bin/lms", host: "127.0.0.1", port: 1234)
        let spec = runner.processSpec()
        #expect(spec.executableURL.path == "/usr/local/bin/lms")
        #expect(spec.arguments == ["server", "start", "--port", "1234"])
    }

    @Test func availableModelsIncludeUnloadedChoices() throws {
        let json = Data(#"{"data":[{"id":"small","state":"loaded","size_bytes":100},{"id":"large","state":"not-loaded","size_bytes":200}]}"#.utf8)
        let models = try LMStudioRunner(binaryPath: "/x").parseAvailableModels(json)
        #expect(models.map(\.name) == ["small", "large"])
    }

    @Test func endpoints() {
        let runner = LMStudioRunner(binaryPath: "/x", host: "127.0.0.1", port: 1234)
        #expect(runner.readinessEndpoint.absoluteString == "http://127.0.0.1:1234/v1/models")
        #expect(runner.modelsEndpoint.absoluteString == "http://127.0.0.1:1234/api/v0/models")
    }

    @Test func parseResidentModelsSurfacesOnlyLoaded() throws {
        let runner = LMStudioRunner(binaryPath: "/x")
        let json = Data("""
        {"object":"list","data":[
          {"id":"qwen2.5-7b-instruct","state":"loaded","size_bytes":4700000000},
          {"id":"llama-3.2-1b","state":"not-loaded","size_bytes":1300000000}
        ]}
        """.utf8)
        let models = try runner.parseResidentModels(json)
        #expect(models.count == 1)
        #expect(models[0].name == "qwen2.5-7b-instruct")
        #expect(models[0].sizeBytes == 4_700_000_000)
    }

    @Test func classifiesOutOfMemory() {
        let runner = LMStudioRunner(binaryPath: "/x")
        let exit = ProcessExit(code: 1)
        #expect(runner.classifyExit(exit, stderr: ["llama.cpp: failed to allocate"]) == .outOfMemory)
        #expect(runner.classifyExit(ProcessExit(code: 0), stderr: []) == .cleanExit)
    }
}
