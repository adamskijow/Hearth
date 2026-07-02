// SPDX-License-Identifier: MIT

import Foundation

/// One known environment variable a runner understands, for the picker in the env
/// editor: the name, a one-line description, and an example value used as the
/// field's placeholder.
public struct RunnerEnvVar: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let example: String

    public init(name: String, summary: String, example: String) {
        self.name = name
        self.summary = summary
        self.example = example
    }
}

/// The commonly-tuned environment variables for each runner, so the env editor can
/// offer a dropdown instead of free text. Not exhaustive of every variable a runner
/// accepts; the editor keeps a "Custom" entry for anything not listed. OLLAMA_HOST
/// is deliberately absent: Hearth derives it from host and port.
public enum RunnerEnvCatalog {
    public static func variables(for runner: String) -> [RunnerEnvVar] {
        switch RunnerKind(fromConfigString: runner) {
        case .lmStudio: return []   // LM Studio is configured in its app, not by env
        case .osaurus: return []    // Osaurus is configured in its app, not by env
        case .mlx: return mlx
        case .ollama: return ollama
        }
    }

    private static let ollama: [RunnerEnvVar] = [
        .init(name: "OLLAMA_KEEP_ALIVE", summary: "How long a model stays loaded in memory after its last use.", example: "30m"),
        .init(name: "OLLAMA_LOAD_TIMEOUT", summary: "How long to wait for a model to load before giving up.", example: "10m"),
        .init(name: "OLLAMA_MAX_LOADED_MODELS", summary: "Maximum number of models kept loaded at the same time.", example: "2"),
        .init(name: "OLLAMA_NUM_PARALLEL", summary: "Parallel requests handled per loaded model.", example: "4"),
        .init(name: "OLLAMA_MAX_QUEUE", summary: "Maximum requests queued before new ones are rejected.", example: "512"),
        .init(name: "OLLAMA_CONTEXT_LENGTH", summary: "Default context window, in tokens.", example: "8192"),
        .init(name: "OLLAMA_FLASH_ATTENTION", summary: "Enable flash attention to cut memory use (1 or 0).", example: "1"),
        .init(name: "OLLAMA_KV_CACHE_TYPE", summary: "KV cache quantization: f16, q8_0, or q4_0.", example: "q8_0"),
        .init(name: "OLLAMA_GPU_OVERHEAD", summary: "Bytes of VRAM to reserve as headroom.", example: "0"),
        .init(name: "OLLAMA_SCHED_SPREAD", summary: "Spread a model across all GPUs (1 or 0).", example: "1"),
        .init(name: "OLLAMA_ORIGINS", summary: "Allowed CORS origins for browser clients.", example: "*"),
        .init(name: "OLLAMA_MODELS", summary: "Directory where models are stored.", example: "/Volumes/AI/models"),
        .init(name: "OLLAMA_NOPRUNE", summary: "Do not prune unused model blobs on startup (1 or 0).", example: "1"),
        .init(name: "OLLAMA_DEBUG", summary: "Enable verbose debug logging (1 or 0).", example: "1"),
    ]

    private static let mlx: [RunnerEnvVar] = [
        .init(name: "HF_HOME", summary: "Hugging Face cache directory mlx_lm loads models from.", example: "~/.cache/huggingface"),
        .init(name: "HF_HUB_OFFLINE", summary: "Use only already-cached models, no network (1 or 0).", example: "1"),
    ]
}
