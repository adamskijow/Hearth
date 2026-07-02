// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Detecting a runner Hearth did not spawn that is already serving on the
/// configured port, so the menu, the welcome window, and `hearth doctor` can warn
/// that managed mode will fight it (the Ollama app is the common case). The decision
/// and the message are pure in `PreexistingRunner`; this is the runtime probe.
enum RunnerCollision {
    /// True when, in managed mode, something is serving on host:port that is not
    /// Hearth's own recorded, live runner.
    static func foreignRunnerServing(config: HearthConfig) async -> Bool {
        guard config.isManaged else { return false }
        guard await answersAsRunner(at: config.makeRunner().readinessEndpoint) else { return false }
        return !hearthRunnerAlive()
    }

    /// Whether any of Hearth's recorded runners (from recent spawns) is still
    /// alive, with the start-time guard so a recycled PID is not mistaken for it.
    /// Hearth records a runner at spawn, before it binds, so any runner that is
    /// ours and serving the port is already recorded by the time it answers; a
    /// foreign runner is not.
    private static func hearthRunnerAlive() -> Bool {
        RunnerStateStore.loadRecorded().contains { recorded in
            guard let live = RunnerStateStore.liveIdentity(pid: recorded.pid) else { return false }
            return live.startTimeSeconds == recorded.startTimeSeconds
        }
    }

    /// True only when the service on the port answers the runner's own readiness
    /// endpoint with success. An unrelated HTTP service that happens to hold the
    /// port (a 404 or 500 on this path) is a port conflict, not a compatible
    /// runner, and must not trigger the switch-to-attached advice; attaching to
    /// it would supervise something that is not a runner. The runner's endpoint
    /// already applies the wildcard-to-loopback dial mapping and IPv6 bracketing
    /// the probes use.
    private static func answersAsRunner(at endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
