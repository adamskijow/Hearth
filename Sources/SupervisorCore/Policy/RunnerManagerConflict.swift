// SPDX-License-Identifier: MIT

import Foundation

/// Detects another launchd job that also keeps the runner alive, most often
/// `brew services`. In managed mode that job fights Hearth over the same runner
/// exactly like a second Hearth would (each restarts what the other stops), so it
/// is the same class of problem the single-instance guard handles, just with a
/// non-Hearth manager. Pure: the app gathers the loaded launchd labels and passes
/// them in, so the rule stays testable.
public enum RunnerManagerConflict {
    /// The launchd label `brew services` uses for a runner, if it has one.
    static func brewServicesLabel(forRunner runner: String) -> String? {
        switch runner.lowercased() {
        case "ollama": return "homebrew.mxcl.ollama"
        // LM Studio and mlx_lm are not managed by brew services.
        default: return nil
        }
    }

    public static func competingLabel(runner: String, loadedLabels: Set<String>) -> String? {
        guard let label = brewServicesLabel(forRunner: runner),
              loadedLabels.contains(label) else { return nil }
        return label
    }

    /// A warning if, in managed mode, another launchd job already manages the
    /// runner. nil otherwise. Attached mode is fine: a brew-services-managed runner
    /// is exactly the kind of thing attached mode is meant to watch.
    public static func warning(runner: String, mode: String, loadedLabels: Set<String>) -> String? {
        guard mode.lowercased() == "managed",
              let label = competingLabel(runner: runner, loadedLabels: loadedLabels) else { return nil }
        return "Something else is already keeping \(runner) alive (\(label), likely `brew services`). If Hearth also starts it, each restarts what the other stops. Either have Hearth watch the existing one instead (attached mode: one click in Hearth's menu, or `hearth mode attached`), or run `brew services stop \(runner)` in Terminal so Hearth is the only manager."
    }
}
