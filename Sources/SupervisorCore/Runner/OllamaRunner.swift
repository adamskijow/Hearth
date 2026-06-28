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
    private let oomSignatures: [String]

    /// Default substrings that, when seen in Ollama or llama.cpp stderr around an
    /// abnormal exit, indicate a unified memory blowout rather than a plain
    /// crash. Matched case insensitively. Conservative on purpose: a false
    /// negative just classifies as a crash, which is still restarted.
    public static let defaultOOMSignatures: [String] = [
        "out of memory",
        "outofmemory",
        "oom",
        "cannot allocate",
        "failed to allocate",
        "unable to allocate",
        "insufficient memory",
        "not enough memory",
        "vk_error_out_of_device_memory",
        "ggml_metal_graph_compute",
        "mtlbuffer",
        "metal buffer",
        "ggml_backend_metal_buffer"
    ]

    public init(binaryPath: String,
                host: String = "127.0.0.1",
                port: Int = 11434,
                oomSignatures: [String] = OllamaRunner.defaultOOMSignatures) {
        self.binaryPath = binaryPath
        self.host = host
        self.port = port
        self.oomSignatures = oomSignatures
    }

    /// The `host:port` string Ollama expects in `OLLAMA_HOST`.
    public var hostPort: String { "\(host):\(port)" }

    public func processSpec() -> ProcessSpec {
        ProcessSpec(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: ["serve"],
            // Set the listen address at spawn. This is the whole point of
            // managed mode: the child's environment is ours to define, so the
            // launchd env trap never gets a chance to bite.
            environmentOverrides: ["OLLAMA_HOST": hostPort]
        )
    }

    public var readinessEndpoint: URL {
        URL(string: "http://\(hostPort)/api/version")!
    }

    public var modelsEndpoint: URL {
        URL(string: "http://\(hostPort)/api/ps")!
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

    public func classifyExit(_ exit: ProcessExit?, stderr: [String]) -> ExitReason {
        guard let exit else { return .running }

        if matchesOOM(stderr) {
            return .outOfMemory
        }
        if exit.wasSignaled {
            return .signal(exit.signal ?? 0)
        }
        if exit.code == 0 {
            return .cleanExit
        }
        return .crash(code: exit.code)
    }

    private func matchesOOM(_ stderr: [String]) -> Bool {
        let haystack = stderr.joined(separator: "\n").lowercased()
        guard !haystack.isEmpty else { return false }
        return oomSignatures.contains { haystack.contains($0.lowercased()) }
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
