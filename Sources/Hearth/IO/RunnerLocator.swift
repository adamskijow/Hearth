// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Finds a runner binary on disk so first run does not fail just because the
/// default path is wrong (Intel Homebrew, the Ollama.app install, a custom
/// location). Read only: it probes well known locations and $PATH and returns the
/// first executable it finds.
enum RunnerLocator {
    /// Candidate locations for a runner kind, most preferred first.
    static func candidates(for runner: String) -> [String] {
        let home = NSHomeDirectory()
        switch runner.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio":
            return ["\(home)/.lmstudio/bin/lms", "/usr/local/bin/lms", "/opt/homebrew/bin/lms"]
                + pathCandidates(for: "lms")
        case "mlx", "mlx_lm", "mlx-lm":
            return ["/opt/homebrew/bin/mlx_lm.server", "/usr/local/bin/mlx_lm.server"]
                + pathCandidates(for: "mlx_lm.server")
        default:
            return [
                "/opt/homebrew/bin/ollama",
                "/usr/local/bin/ollama",
                "/Applications/Ollama.app/Contents/Resources/ollama"
            ] + pathCandidates(for: "ollama")
        }
    }

    /// The first candidate that exists and is executable, or nil.
    static func locate(_ runner: String) -> String? {
        let fm = FileManager.default
        return candidates(for: runner).first { fm.isExecutableFile(atPath: $0) }
    }

    private static func pathCandidates(for name: String) -> [String] {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return [] }
        return path.split(separator: ":").map { "\($0)/\(name)" }
    }
}
