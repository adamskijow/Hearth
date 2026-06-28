// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct OllamaRunnerTests {
    @Test func processSpecSetsOllamaHostAtSpawn() {
        let runner = OllamaRunner(binaryPath: "/opt/homebrew/bin/ollama", host: "0.0.0.0", port: 1234)
        let spec = runner.processSpec()
        #expect(spec.executableURL.path == "/opt/homebrew/bin/ollama")
        #expect(spec.arguments == ["serve"])
        // The whole managed mode point: OLLAMA_HOST is pinned at spawn.
        #expect(spec.environmentOverrides["OLLAMA_HOST"] == "0.0.0.0:1234")
    }

    @Test func endpoints() {
        let runner = OllamaRunner(binaryPath: "/x", host: "127.0.0.1", port: 11434)
        #expect(runner.readinessEndpoint.absoluteString == "http://127.0.0.1:11434/api/version")
        #expect(runner.modelsEndpoint.absoluteString == "http://127.0.0.1:11434/api/ps")
    }

    @Test func parseResidentModels() throws {
        let runner = OllamaRunner(binaryPath: "/x")
        let json = Data("""
        {"models":[
          {"name":"llama3:8b","model":"llama3:8b","size":5300000000,"expires_at":"2026-06-27T12:00:00.000Z"},
          {"name":"qwen2:0.5b","model":"qwen2:0.5b","size":400000000,"expires_at":"2026-06-27T12:05:00Z"}
        ]}
        """.utf8)
        let models = try runner.parseResidentModels(json)
        #expect(models.count == 2)
        #expect(models[0].name == "llama3:8b")
        #expect(models[0].sizeBytes == 5_300_000_000)
        #expect(models[0].expiresAt != nil)
        #expect(models[1].name == "qwen2:0.5b")
    }

    @Test func parseEmptyModels() throws {
        let runner = OllamaRunner(binaryPath: "/x")
        let json = Data(#"{"models":[]}"#.utf8)
        #expect(try runner.parseResidentModels(json).isEmpty)
    }

    @Test func parseMalformedThrows() {
        let runner = OllamaRunner(binaryPath: "/x")
        let json = Data("not json".utf8)
        #expect(throws: (any Error).self) {
            try runner.parseResidentModels(json)
        }
    }
}
