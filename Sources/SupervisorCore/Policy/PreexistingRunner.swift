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
        return "A compatible runner is already serving on the configured port (\(example)). In managed mode Hearth launches its own and they fight over the port; run `hearth mode attached` to watch the running one, or quit it so Hearth can manage its own."
    }

    public static func unknownListenerWarning(runner: String, host: String, port: Int) -> String {
        "Something is listening on \(host):\(port), but it did not answer as \(runner). In managed mode Hearth may fail to bind this port; stop that process or change Hearth's host/port before starting managed supervision."
    }

    public static func attachedMissingWarning(runner: String, host: String, port: Int, listenerPresent: Bool) -> String {
        if listenerPresent {
            return "Attached mode is set, but the service on \(host):\(port) did not answer as \(runner). Start the matching runner there, switch runner/port, or run `hearth mode managed` so Hearth starts its own."
        }
        return "Attached mode is set, but nothing is serving on \(host):\(port). Start \(runner), or run `hearth mode managed` so Hearth starts and restarts its own runner."
    }
}
