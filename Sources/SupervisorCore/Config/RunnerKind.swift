// SPDX-License-Identifier: MIT

import Foundation

/// The runner Hearth supervises, resolved from the config `runner` string and its
/// aliases. This is the one place the aliases are matched: every per-runner switch
/// across config, diagnostics, location, the env catalog, and the UI routes through
/// a kind instead of re-listing "lmstudio"/"lm-studio"/"lm_studio" (and the mlx
/// variants) in each file. Anything unrecognized resolves to ollama, which is the
/// historic default arm of all those switches, so behavior is unchanged.
public enum RunnerKind: String, CaseIterable, Sendable {
    case ollama
    case lmStudio
    case mlx
    case osaurus

    public init(fromConfigString raw: String) {
        switch raw.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio": self = .lmStudio
        case "mlx", "mlx_lm", "mlx-lm": self = .mlx
        case "osaurus": self = .osaurus
        default: self = .ollama
        }
    }

    /// Every accepted config `runner` string (all kinds and their aliases). Used by
    /// the doctor check that warns on an unrecognized value, which the kind mapping
    /// itself cannot express since it defaults anything unknown to ollama.
    public static let knownConfigStrings: [String] = [
        "ollama", "lmstudio", "lm-studio", "lm_studio", "mlx", "mlx_lm", "mlx-lm", "osaurus",
    ]

    /// Human-readable name for menus and messages.
    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .mlx: return "mlx_lm"
        case .osaurus: return "Osaurus"
        }
    }

    /// A one-line install hint shown when the runner binary cannot be found.
    public var installHint: String {
        switch self {
        case .ollama: return "brew install ollama"
        case .lmStudio: return "brew install --cask lm-studio"
        case .mlx: return "pip install mlx-lm"
        case .osaurus: return "brew install --cask osaurus"
        }
    }
}
