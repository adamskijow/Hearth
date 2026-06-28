// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Finds a runner binary on disk so first run does not fail just because the
/// default path is wrong (Intel Homebrew, the Ollama.app install, a custom
/// location). Read only: it probes well known locations and $PATH and returns the
/// first executable it finds.
enum RunnerLocator {
    /// Candidate locations for a runner kind, most preferred first. The pure
    /// ordering lives in `RunnerLocation`; this binds it to the live environment.
    static func candidates(for runner: String) -> [String] {
        RunnerLocation.candidates(
            for: runner,
            home: NSHomeDirectory(),
            path: ProcessInfo.processInfo.environment["PATH"]
        )
    }

    /// The first candidate that exists and is executable, or nil.
    static func locate(_ runner: String) -> String? {
        let fm = FileManager.default
        return candidates(for: runner).first { fm.isExecutableFile(atPath: $0) }
    }
}
