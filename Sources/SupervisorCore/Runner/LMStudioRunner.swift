// SPDX-License-Identifier: MIT

import Foundation

/// The LM Studio implementation of `Runner`. It exists to prove the seam: adding
/// a second runner touches nothing in the engine or the decision logic, only this
/// file. Everything LM Studio specific is fenced here: the `lms server start`
/// launch, the OpenAI compatible `/v1/models` readiness endpoint, and the LM
/// Studio REST `/api/v0/models` endpoint with its loaded versus not loaded state.
///
/// Note on launch: `lms server start` may hand the server off to a background
/// service rather than staying in the foreground, so managed mode is best effort
/// for LM Studio. Attached mode (point Hearth at an already running LM Studio
/// server and let it monitor and alert) is the reliable path, and is what the
/// README recommends for this runner.
public struct LMStudioRunner: Runner {
    public let name = "LM Studio"

    private let binaryPath: String
    private let host: String
    private let port: Int
    private let extraEnvironment: [String: String]
    private let oomSignatures: [String]

    public init(binaryPath: String,
                host: String = "127.0.0.1",
                port: Int = 1234,
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
            arguments: ["server", "start", "--port", "\(port)"],
            environmentOverrides: extraEnvironment
        )
    }

    /// OpenAI compatible model list. A 200 here means the server is up.
    public var readinessEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/v1/models")
    }

    /// LM Studio native REST model list, which reports load state per model.
    public var modelsEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/api/v0/models")
    }

    /// Parse `/api/v0/models` and surface only the models LM Studio reports as
    /// loaded, so the menubar shows what is actually resident rather than every
    /// downloaded model.
    public func parseResidentModels(_ data: Data) throws -> [ResidentModel] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data
            .filter { ($0.state ?? "").lowercased() == "loaded" }
            .map { ResidentModel(name: $0.id, sizeBytes: $0.sizeBytes) }
    }

    public func classifyExit(_ exit: ProcessExit?, stderr: [String]) -> ExitReason {
        RunnerHeuristics.classify(exit, stderr: stderr, oomSignatures: oomSignatures)
    }

    /// A one-token chat completion against the named model, so the deep probe
    /// catches a wedged LM Studio server that still answers `/v1/models`.
    public func deepReadinessRequest(model: String) -> DeepProbeRequest? {
        openAIDeepReadinessRequest(host: host, port: port, model: model)
    }
}

// MARK: - LM Studio /api/v0/models JSON shape

private struct ModelsResponse: Decodable {
    var data: [Model]
}

private struct Model: Decodable {
    var id: String
    var state: String?
    var sizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case sizeBytes = "size_bytes"
    }
}
