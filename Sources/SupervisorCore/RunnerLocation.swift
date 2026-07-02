// SPDX-License-Identifier: MIT

import Foundation

/// Pure logic for where a runner binary might live, so first run does not fail
/// just because the default path is wrong (Intel Homebrew, the Ollama.app
/// install, a custom location). The home directory and PATH are passed in, so
/// this is testable without touching the environment; the actual on disk probe
/// (which path exists and is executable) lives in the app layer.
public enum RunnerLocation {
    /// Candidate locations for a runner kind, most preferred first. `path` is the
    /// PATH environment value (colon separated entries), or nil.
    public static func candidates(for runner: String, home: String, path: String?) -> [String] {
        switch RunnerKind(fromConfigString: runner) {
        case .lmStudio:
            return ["\(home)/.lmstudio/bin/lms", "/usr/local/bin/lms", "/opt/homebrew/bin/lms"]
                + pathCandidates(for: "lms", path: path)
        case .mlx:
            return ["/opt/homebrew/bin/mlx_lm.server", "/usr/local/bin/mlx_lm.server"]
                + pathCandidates(for: "mlx_lm.server", path: path)
        case .osaurus:
            return [
                "/Applications/Osaurus.app/Contents/MacOS/osaurus",
                "/opt/homebrew/bin/osaurus",
                "/usr/local/bin/osaurus"
            ] + pathCandidates(for: "osaurus", path: path)
        case .ollama:
            return [
                "/opt/homebrew/bin/ollama",
                "/usr/local/bin/ollama",
                "/Applications/Ollama.app/Contents/Resources/ollama"
            ] + pathCandidates(for: "ollama", path: path)
        }
    }

    private static func pathCandidates(for name: String, path: String?) -> [String] {
        guard let path else { return [] }
        return path.split(separator: ":").map { "\($0)/\(name)" }
    }
}
