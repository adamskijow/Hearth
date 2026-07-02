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
        return "\(runner) is already running and serving (\(example)). If Hearth starts its own copy too, the two collide over the same port. Have Hearth watch the one already running (attached mode: one click in Hearth's menu, or `hearth mode attached`), or quit it so Hearth can start and manage its own."
    }

    public static func unknownListenerWarning(runner: String, host: String, port: Int) -> String {
        "Something else is listening on \(host):\(port), and it did not answer as \(runner). Hearth's own runner cannot start on a busy port; quit that process, or change Hearth's host/port, before letting Hearth start the runner."
    }

    public static func attachedMissingWarning(runner: String, host: String, port: Int, listenerPresent: Bool) -> String {
        if listenerPresent {
            return "Hearth is set to watch an existing runner (attached mode), but the service on \(host):\(port) did not answer as \(runner). Start the matching runner there, fix the runner or port, or run `hearth mode managed` so Hearth starts its own."
        }
        return "Hearth is set to watch an existing runner (attached mode), but nothing is serving on \(host):\(port). In this mode Hearth will not start it for you: start \(runner) yourself, or run `hearth mode managed` so Hearth starts and restarts it."
    }
}
