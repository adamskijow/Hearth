// SPDX-License-Identifier: MIT

import Foundation

/// The host a probe should dial for a runner bound to `host`. A wildcard bind
/// address (`0.0.0.0`, `::`) tells the runner to listen on every interface, but
/// it is not itself a connectable destination, so probes from this machine
/// target loopback instead. Only probing uses this mapping; a managed runner is
/// still launched with the raw configured host as its bind address.
public func probeHost(for host: String) -> String {
    switch host {
    case "0.0.0.0": return "127.0.0.1"
    case "::", "::0": return "::1"
    default: return host
    }
}

/// Build a runner HTTP endpoint from a configured host and port, mapping a
/// wildcard bind host to loopback so the URL is actually connectable. Never
/// traps: a malformed host or port yields an unconnectable URL, so a probe fails
/// gracefully (the supervisor treats it as not serving and restarts) instead of
/// crashing the whole supervisor on a config typo.
func runnerEndpoint(host: String, port: Int, path: String) -> URL {
    let dialed = probeHost(for: host)
    // An IPv6 literal needs brackets in a URL authority.
    let authority = dialed.contains(":") && !dialed.hasPrefix("[") ? "[\(dialed)]" : dialed
    return URL(string: "http://\(authority):\(port)\(path)")
        ?? URL(string: "http://127.0.0.1:0\(path)")
        ?? URL(string: "http://127.0.0.1:0/")!
}

/// A model the runner currently holds resident in memory, as reported by its own
/// API. The supervisor surfaces this for situational awareness only. It never
/// chooses, loads, or unloads a model.
public struct ResidentModel: Sendable, Equatable {
    public var name: String
    public var sizeBytes: Int64?
    public var expiresAt: Date?

    public init(name: String, sizeBytes: Int64? = nil, expiresAt: Date? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.expiresAt = expiresAt
    }
}

/// Why the child process ended, classified from its exit status plus captured
/// stderr. The interesting distinction is a plain crash versus an out of memory
/// kill, because on a unified memory Mac an oversized model blows the box rather
/// than failing one request, and the right response differs.
public enum ExitReason: Sendable, Equatable {
    /// Still running; not an exit at all.
    case running
    /// Exited with status zero.
    case cleanExit
    /// Exited non zero with no out of memory signature.
    case crash(code: Int32)
    /// Out of memory, detected from the exit plus stderr signature.
    case outOfMemory
    /// Killed by a signal with no out of memory signature.
    case signal(Int32)
    /// Dead, but the cause could not be classified.
    case unknown

    /// A short human label for notifications and the menubar.
    public var label: String {
        switch self {
        case .running: return "running"
        case .cleanExit: return "clean exit"
        case .crash(let code): return "crash (code \(code))"
        case .outOfMemory: return "out of memory"
        case .signal(let sig): return "killed by signal \(sig)"
        case .unknown: return "unknown exit"
        }
    }
}

/// Heuristics shared across runners. The out of memory signatures are matched
/// case insensitively against captured stderr around an abnormal exit; a unified
/// memory blowout tends to look the same whichever runner sat on top of it.
///
/// Verification status: confirmed ABSENT from a real Ollama 0.30.11's normal
/// output (so they will not false-positive a healthy runner), but NOT yet
/// confirmed to fire on a real out of memory kill, which could not be induced on
/// 128 GiB unified-memory hardware. The Metal specific entries in particular
/// remain heuristics until a real Metal OOM signature is captured. The bare token
/// "oom" was deliberately removed: it is a substring of common words (room, zoom,
/// boom) and is already covered by "out of memory" / "outofmemory".
public enum RunnerHeuristics {
    public static let oomSignatures: [String] = [
        "out of memory",
        "outofmemory",
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

    /// Classify an exit given its status and stderr, using the supplied out of
    /// memory signatures. Shared so every runner classifies the same way unless
    /// it has a reason not to.
    public static func classify(_ exit: ProcessExit?,
                                stderr: [String],
                                oomSignatures: [String] = RunnerHeuristics.oomSignatures) -> ExitReason {
        guard let exit else { return .running }
        let haystack = stderr.joined(separator: "\n").lowercased()
        if !haystack.isEmpty, oomSignatures.contains(where: { haystack.contains($0.lowercased()) }) {
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
}

/// A request that exercises real inference, for the optional deep readiness probe.
/// The shallow readiness endpoint only proves the HTTP server answers; a deep probe
/// proves the model runner is not wedged.
public struct DeepProbeRequest: Sendable, Equatable {
    public var url: URL
    public var body: Data
    public init(url: URL, body: Data) {
        self.url = url
        self.body = body
    }
}

/// A one-token OpenAI-style chat completion, the deep probe for runners that expose
/// the OpenAI API (mlx_lm, LM Studio). nil for an empty model.
func openAIDeepReadinessRequest(host: String, port: Int, model: String) -> DeepProbeRequest? {
    let trimmed = model.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let payload: [String: Any] = [
        "model": trimmed,
        "messages": [["role": "user", "content": "ping"]],
        "max_tokens": 1,
        "stream": false,
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    return DeepProbeRequest(url: runnerEndpoint(host: host, port: port, path: "/v1/chat/completions"), body: body)
}

/// The seam that keeps each runner's specifics in one place. Ollama is the first
/// implementation; LM Studio and mlx_lm can be added later without the engine or
/// the decision logic learning anything Ollama specific. Every Ollama string,
/// path, endpoint, and log signature lives behind this protocol.
public protocol Runner: Sendable {
    /// A short display name, for example "Ollama".
    var name: String { get }

    /// How to launch the runner as a managed child, including the environment
    /// overrides that pin its listen address.
    func processSpec() -> ProcessSpec

    /// The endpoint a successful GET on which means "ready to serve".
    var readinessEndpoint: URL { get }

    /// The endpoint reporting currently resident models.
    var modelsEndpoint: URL { get }

    /// Parse the resident models response body. Throws on malformed input.
    func parseResidentModels(_ data: Data) throws -> [ResidentModel]

    /// Classify how the child exited, given its exit status and recent stderr.
    /// Pure: same inputs always yield the same verdict, so it is testable from
    /// fixture log lines with no real process.
    func classifyExit(_ exit: ProcessExit?, stderr: [String]) -> ExitReason

    /// A request that runs a tiny inference against the named model, for the
    /// optional deep readiness probe. nil when the runner cannot build one (an empty
    /// model, or a runner without an inference endpoint Hearth knows). Default: nil.
    func deepReadinessRequest(model: String) -> DeepProbeRequest?
}

public extension Runner {
    func deepReadinessRequest(model: String) -> DeepProbeRequest? { nil }
}
