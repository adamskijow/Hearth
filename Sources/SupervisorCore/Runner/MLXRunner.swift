// SPDX-License-Identifier: MIT

import Foundation

/// The mlx_lm implementation of `Runner`, the third runner. It launches
/// `mlx_lm.server` and reads its OpenAI compatible endpoints. As with the other
/// runners, nothing outside this file knows anything mlx_lm specific.
///
/// Current mlx_lm releases require a model when the server starts. Hearth passes
/// the configured Hugging Face repository ID or local model path as one process
/// argument, preserving spaces in a local path. Config admission prevents a
/// managed launch when it is absent; attached mode never launches this spec.
public struct MLXRunner: Runner {
    public let name = "mlx_lm"

    private let binaryPath: String
    private let model: String?
    private let host: String
    private let port: Int
    private let extraEnvironment: [String: String]
    private let oomSignatures: [String]

    public init(binaryPath: String,
                model: String? = nil,
                host: String = "127.0.0.1",
                port: Int = 8080,
                extraEnvironment: [String: String] = [:],
                oomSignatures: [String] = RunnerHeuristics.oomSignatures) {
        self.binaryPath = binaryPath
        self.model = model
        self.host = host
        self.port = port
        self.extraEnvironment = extraEnvironment
        self.oomSignatures = oomSignatures
    }

    public func processSpec() -> ProcessSpec {
        var arguments: [String] = []
        if let model { arguments += ["--model", model] }
        arguments += ["--host", host, "--port", "\(port)"]
        return ProcessSpec(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: arguments,
            environmentOverrides: extraEnvironment
        )
    }

    public var readinessEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/v1/models")
    }

    public var modelsEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/v1/models")
    }

    /// The OpenAI compatible model list: `{ "data": [ { "id": ... } ] }`.
    public func parseResidentModels(_ data: Data) throws -> [ResidentModel] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { ResidentModel(name: $0.id) }
    }

    public func classifyExit(_ exit: ProcessExit?, stderr: [String]) -> ExitReason {
        RunnerHeuristics.classify(exit, stderr: stderr, oomSignatures: oomSignatures)
    }

    /// A one-token chat completion against the named model, so the deep probe
    /// catches a wedged mlx_lm that still answers `/v1/models`.
    public func deepReadinessRequest(model: String, unloadAfter: Bool) -> DeepProbeRequest? {
        openAIDeepReadinessRequest(host: host, port: port, model: model)
    }
}

// MARK: - OpenAI /v1/models JSON shape

private struct ModelsResponse: Decodable {
    var data: [Model]
}

private struct Model: Decodable {
    var id: String
}
