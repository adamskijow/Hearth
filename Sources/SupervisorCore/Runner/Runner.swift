// SPDX-License-Identifier: MIT

import Foundation

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
}
