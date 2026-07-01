// SPDX-License-Identifier: MIT

import Foundation

/// The mlx_lm implementation of `Runner`, the third runner. It launches
/// `mlx_lm.server` and reads its OpenAI compatible endpoints. As with the other
/// runners, nothing outside this file knows anything mlx_lm specific.
///
/// Hearth never picks a model: the server is launched with only a host and port,
/// and clients name the model per request. If a given mlx_lm version insists on a
/// model at launch, that is a choice you make in your own wrapper, not here.
public struct MLXRunner: Runner {
    public let name = "mlx_lm"

    private let binaryPath: String
    private let host: String
    private let port: Int
    private let extraEnvironment: [String: String]
    private let oomSignatures: [String]

    public init(binaryPath: String,
                host: String = "127.0.0.1",
                port: Int = 8080,
                extraEnvironment: [String: String] = [:],
                oomSignatures: [String] = RunnerHeuristics.oomSignatures) {
        self.binaryPath = binaryPath
        self.host = host
        self.port = port
        self.extraEnvironment = extraEnvironment
        self.oomSignatures = oomSignatures
    }

    public func processSpec() -> ProcessSpec {
        ProcessSpec(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: ["--host", host, "--port", "\(port)"],
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
    public func deepReadinessRequest(model: String) -> DeepProbeRequest? {
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
