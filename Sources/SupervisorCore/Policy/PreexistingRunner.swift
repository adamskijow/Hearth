// SPDX-License-Identifier: MIT

import Foundation

/// Guidance when, in managed mode, a runner Hearth did not spawn is already serving
/// on the configured port. Managed mode launches its own runner, so it fights the
/// existing one for the port; the fix is to watch it (attached mode) or stop it.
/// This is the most common first-run snag, because the official Ollama app auto-runs
/// the server, so a new user who installed Ollama the normal way already has one up.
/// Pure so the message is testable; the app supplies the runtime probe result.
public enum PreexistingRunner {
    public static func warning(runner: String, mode: String, foreignRunnerServing: Bool) -> String? {
        guard mode.lowercased() == "managed", foreignRunnerServing else { return nil }
        let example = runner.lowercased() == "ollama"
            ? "often the Ollama app, or an `ollama serve` you started"
            : "a runner you started yourself"
        return "Something is already serving on the runner's port (\(example)). In managed mode Hearth launches its own and they fight over the port; set mode to attached so Hearth watches the running one, or quit it so Hearth can manage its own."
    }
}
