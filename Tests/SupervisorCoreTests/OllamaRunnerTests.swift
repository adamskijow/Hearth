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

    @Test func extraEnvironmentIsPassedThroughButHostStaysAuthoritative() {
        // A hand-tuned setup keeps its knobs, while the host-derived OLLAMA_HOST
        // always wins over any OLLAMA_HOST the user put in runnerEnv.
        let runner = OllamaRunner(
            binaryPath: "/opt/homebrew/bin/ollama",
            host: "0.0.0.0", port: 11434,
            extraEnvironment: ["OLLAMA_LOAD_TIMEOUT": "10m", "OLLAMA_KEEP_ALIVE": "30m", "OLLAMA_HOST": "127.0.0.1:99"])
        let env = runner.processSpec().environmentOverrides
        #expect(env["OLLAMA_LOAD_TIMEOUT"] == "10m")
        #expect(env["OLLAMA_KEEP_ALIVE"] == "30m")
        #expect(env["OLLAMA_HOST"] == "0.0.0.0:11434")   // host wins, not the runnerEnv value
    }

    @Test func deepReadinessRequestIsAOneTokenGenerate() throws {
        let runner = OllamaRunner(binaryPath: "/x", host: "127.0.0.1", port: 11434)
        let req = try #require(runner.deepReadinessRequest(model: "llama3:8b"))
        #expect(req.url.absoluteString == "http://127.0.0.1:11434/api/generate")
        let json = try JSONSerialization.jsonObject(with: req.body) as? [String: Any]
        #expect(json?["model"] as? String == "llama3:8b")
        #expect(json?["stream"] as? Bool == false)
        // An empty or blank model means no deep probe.
        #expect(runner.deepReadinessRequest(model: "   ") == nil)
    }

    @Test func endpoints() {
        let runner = OllamaRunner(binaryPath: "/x", host: "127.0.0.1", port: 11434)
        #expect(runner.readinessEndpoint.absoluteString == "http://127.0.0.1:11434/api/version")
        #expect(runner.modelsEndpoint.absoluteString == "http://127.0.0.1:11434/api/ps")
        #expect(runner.availableModelsEndpoint.absoluteString == "http://127.0.0.1:11434/api/tags")
    }

    @Test func parsesAvailableModelsForProbeSetup() throws {
        let runner = OllamaRunner(binaryPath: "/x")
        let json = Data(#"{"models":[{"name":"qwen2.5:0.5b","size":400000000},{"model":"llama3:8b","size":5300000000}]}"#.utf8)
        let models = try runner.parseAvailableModels(json)
        #expect(models == [
            AvailableModel(name: "qwen2.5:0.5b", sizeBytes: 400_000_000),
            AvailableModel(name: "llama3:8b", sizeBytes: 5_300_000_000),
        ])
    }

    @Test func wildcardHostBindsAllInterfacesButProbesLoopback() throws {
        let runner = OllamaRunner(binaryPath: "/x", host: "0.0.0.0", port: 11434)
        // The bind address is untouched: the child listens on every interface.
        #expect(runner.processSpec().environmentOverrides["OLLAMA_HOST"] == "0.0.0.0:11434")
        // The probe URLs dial loopback, because 0.0.0.0 is not connectable, so
        // readiness, doctor, and wait-ready agree with the raw port check.
        #expect(runner.readinessEndpoint.absoluteString == "http://127.0.0.1:11434/api/version")
        #expect(runner.modelsEndpoint.absoluteString == "http://127.0.0.1:11434/api/ps")
        let deep = try #require(runner.deepReadinessRequest(model: "llama3:8b"))
        #expect(deep.url.absoluteString == "http://127.0.0.1:11434/api/generate")
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

    /// Reconciled against a live capture. Real Ollama /api/ps carries more fields
    /// than the hand-written fixtures (digest, details, size_vram, context_length)
    /// and an expires_at with microsecond precision and a timezone offset. See
    /// tests/Fixtures/real/ollama-ps.json (Ollama 0.30.11).
    @Test func parseRealPSCaptureFromOllama() throws {
        let runner = OllamaRunner(binaryPath: "/x")
        let json = Data(#"""
        {"models":[{"name":"qwen2.5:0.5b","model":"qwen2.5:0.5b","size":928755219,"digest":"a8b0c51577010a279d933d14c2a8ab4b268079d44c5c8830c0a93900f1827c67","details":{"parent_model":"","format":"gguf","family":"qwen2","families":["qwen2"],"parameter_size":"494.03M","quantization_level":"Q4_K_M"},"expires_at":"2026-06-28T07:22:51.358551-04:00","size_vram":928755219,"context_length":32768}]}
        """#.utf8)
        let models = try runner.parseResidentModels(json)
        #expect(models.count == 1)
        #expect(models[0].name == "qwen2.5:0.5b")
        #expect(models[0].sizeBytes == 928_755_219)
        // The microsecond-and-offset timestamp must parse to a real date, not fall
        // back to the epoch.
        let expires = try #require(models[0].expiresAt)
        #expect(Calendar(identifier: .gregorian).component(.year, from: expires) == 2026)
    }
}
