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
        guard await portIsServing(host: config.host, port: config.port) else { return false }
        return !hearthRunnerAlive()
    }

    /// Whether Hearth's recorded runner (from the last spawn) is still alive, with
    /// the start-time guard so a recycled PID is not mistaken for it. Hearth records
    /// a runner at spawn, before it binds, so any runner that is ours and serving the
    /// port is already recorded by the time it answers; a foreign runner is not.
    private static func hearthRunnerAlive() -> Bool {
        guard let data = try? Data(contentsOf: RunnerStateStore.url),
              let recorded = try? JSONDecoder().decode(RunnerProcessIdentity.self, from: data),
              let live = RunnerStateStore.liveIdentity(pid: recorded.pid) else { return false }
        return live.startTimeSeconds == recorded.startTimeSeconds
    }

    private static func portIsServing(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            _ = try await URLSession.shared.data(for: request)
            return true   // any HTTP response means something is listening
        } catch {
            // Connection refused is the only outcome that means nothing is there.
            let ns = error as NSError
            return !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotConnectToHost)
        }
    }
}
