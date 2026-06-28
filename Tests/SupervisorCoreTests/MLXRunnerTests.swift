// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct MLXRunnerTests {
    @Test func processSpecLaunchesTheServer() {
        let runner = MLXRunner(binaryPath: "/opt/homebrew/bin/mlx_lm.server", host: "127.0.0.1", port: 8080)
        let spec = runner.processSpec()
        #expect(spec.executableURL.path == "/opt/homebrew/bin/mlx_lm.server")
        #expect(spec.arguments == ["--host", "127.0.0.1", "--port", "8080"])
    }

    @Test func endpointsAreOpenAICompatible() {
        let runner = MLXRunner(binaryPath: "/x", host: "127.0.0.1", port: 8080)
        #expect(runner.readinessEndpoint.absoluteString == "http://127.0.0.1:8080/v1/models")
        #expect(runner.modelsEndpoint.absoluteString == "http://127.0.0.1:8080/v1/models")
    }

    @Test func parseResidentModels() throws {
        let runner = MLXRunner(binaryPath: "/x")
        let json = Data("""
        {"object":"list","data":[
          {"id":"mlx-community/Qwen2.5-7B-Instruct-4bit"},
          {"id":"mlx-community/Llama-3.2-1B-4bit"}
        ]}
        """.utf8)
        let models = try runner.parseResidentModels(json)
        #expect(models.map(\.name) == [
            "mlx-community/Qwen2.5-7B-Instruct-4bit",
            "mlx-community/Llama-3.2-1B-4bit"
        ])
    }

    @Test func classifiesExits() {
        let runner = MLXRunner(binaryPath: "/x")
        #expect(runner.classifyExit(ProcessExit(code: 0), stderr: []) == .cleanExit)
        #expect(runner.classifyExit(ProcessExit(code: 1), stderr: ["mlx: out of memory"]) == .outOfMemory)
    }

    @Test func configSelectsMLX() {
        let config = HearthConfig(runner: "mlx", port: 8080)
        let runner = config.makeRunner()
        #expect(runner.name == "mlx_lm")
        #expect(config.selectedBinaryPath == HearthConfig.defaultMLXBinaryPath)
    }
}
