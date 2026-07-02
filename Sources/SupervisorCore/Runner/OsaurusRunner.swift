// SPDX-License-Identifier: MIT

import Foundation

/// The Osaurus implementation of `Runner`, the fourth runner: a native MLX
/// server for Apple Silicon with OpenAI compatible endpoints, serving on port
/// 1337 by default. As with the other runners, nothing outside this file knows
/// anything Osaurus specific.
///
/// Note on launch: like LM Studio's `lms`, the `osaurus` CLI is the app binary
/// and `osaurus serve` may hand the server off rather than staying in the
/// foreground (it has its own `osaurus stop`). Attached mode, watching a server
/// you started with `osaurus serve`, is the recommended path; managed mode is
/// best effort, and the doctor says so.
public struct OsaurusRunner: Runner {
    public let name = "Osaurus"

    private let binaryPath: String
    private let host: String
    private let port: Int
    private let extraEnvironment: [String: String]
    private let oomSignatures: [String]

    public init(binaryPath: String,
                host: String = "127.0.0.1",
                port: Int = 1337,
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
            arguments: ["serve", "--port", "\(port)"],
            environmentOverrides: extraEnvironment
        )
    }

    public var readinessEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/v1/models")
    }

    public var modelsEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/v1/models")
    }

    /// The OpenAI compatible model list: `{ "data": [ { "id": ... } ] }`. As with
    /// mlx_lm, this can mean "known" rather than "loaded"; the docs say so.
    public func parseResidentModels(_ data: Data) throws -> [ResidentModel] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { ResidentModel(name: $0.id) }
    }

    public func classifyExit(_ exit: ProcessExit?, stderr: [String]) -> ExitReason {
        RunnerHeuristics.classify(exit, stderr: stderr, oomSignatures: oomSignatures)
    }

    /// A one-token chat completion against the named model, so the deep probe
    /// catches a wedged Osaurus that still answers `/v1/models`.
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
