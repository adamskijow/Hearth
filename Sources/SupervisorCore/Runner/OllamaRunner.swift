// SPDX-License-Identifier: MIT

import Foundation

/// The Ollama implementation of `Runner`. Everything Ollama specific is fenced
/// in here: the `serve` subcommand, the `OLLAMA_HOST` environment override, the
/// `/api/version` and `/api/ps` endpoints, the resident models JSON shape, and
/// the stderr signatures that mark an out of memory death.
public struct OllamaRunner: Runner {
    public let name = "Ollama"

    private let binaryPath: String
    private let host: String
    private let port: Int
    private let extraEnvironment: [String: String]
    private let oomSignatures: [String]

    /// Default out of memory stderr signatures. Shared across runners because a
    /// unified memory blowout looks the same underneath. Conservative on purpose:
    /// a false negative just classifies as a crash, which is still restarted.
    public static let defaultOOMSignatures: [String] = RunnerHeuristics.oomSignatures

    public init(binaryPath: String,
                host: String = "127.0.0.1",
                port: Int = 11434,
                extraEnvironment: [String: String] = [:],
                oomSignatures: [String] = OllamaRunner.defaultOOMSignatures) {
        self.binaryPath = binaryPath
        self.host = host
        self.port = port
        self.extraEnvironment = extraEnvironment
        self.oomSignatures = oomSignatures
    }

    /// The `host:port` string Ollama expects in `OLLAMA_HOST`.
    public var hostPort: String { "\(host):\(port)" }

    public func processSpec() -> ProcessSpec {
        // Start from the user's extra environment, then set the listen address
        // last so the host-derived OLLAMA_HOST always wins: managed mode owns the
        // bind address, and the child's environment being ours to define is the
        // whole point (the launchd env trap never gets a chance to bite).
        var environment = extraEnvironment
        environment["OLLAMA_HOST"] = hostPort
        return ProcessSpec(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: ["serve"],
            environmentOverrides: environment
        )
    }

    public var readinessEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/api/version")
    }

    public var modelsEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/api/ps")
    }

    public var availableModelsEndpoint: URL {
        runnerEndpoint(host: host, port: port, path: "/api/tags")
    }

    public func parseResidentModels(_ data: Data) throws -> [ResidentModel] {
        let decoded = try JSONDecoder.ollama.decode(PSResponse.self, from: data)
        return decoded.models.map { entry in
            ResidentModel(
                name: entry.name ?? entry.model ?? "unknown",
                sizeBytes: entry.size,
                expiresAt: entry.expiresAt
            )
        }
    }

    public func parseAvailableModels(_ data: Data) throws -> [AvailableModel] {
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map { entry in
            AvailableModel(name: entry.name ?? entry.model ?? "unknown", sizeBytes: entry.size)
        }
    }

    public func classifyExit(_ exit: ProcessExit?, stderr: [String]) -> ExitReason {
        RunnerHeuristics.classify(exit, stderr: stderr, oomSignatures: oomSignatures)
    }

    /// A one-token `/api/generate` against the named model. This actually runs the
    /// model, so it catches a wedged runner that still answers `/api/version`. It
    /// sends no `keep_alive`, so the runner's own policy (the user's
    /// `OLLAMA_KEEP_ALIVE`) decides how long the model stays resident; the probe
    /// observes, it does not impose a residency of its own.
    public func deepReadinessRequest(model: String) -> DeepProbeRequest? {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let payload: [String: Any] = [
            "model": trimmed,
            "prompt": "ping",
            "stream": false,
            "options": ["num_predict": 1],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return DeepProbeRequest(url: runnerEndpoint(host: host, port: port, path: "/api/generate"), body: body)
    }
}

// MARK: - Ollama /api/ps JSON shape

private struct PSResponse: Decodable {
    var models: [PSModel]
}

private struct PSModel: Decodable {
    var name: String?
    var model: String?
    var size: Int64?
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case model
        case size
        case expiresAt = "expires_at"
    }
}

private struct TagsResponse: Decodable {
    var models: [TagsModel]
}

private struct TagsModel: Decodable {
    var name: String?
    var model: String?
    var size: Int64?
}

extension JSONDecoder {
    /// Ollama timestamps are RFC 3339. Be lenient: fall back to no date rather
    /// than failing the whole parse if the format drifts.
    fileprivate static var ollama: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // Build the formatter inside the closure so nothing non Sendable is
            // captured across the @Sendable boundary.
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string) ?? Date(timeIntervalSince1970: 0)
        }
        return decoder
    }
}
