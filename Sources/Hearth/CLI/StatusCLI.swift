// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Terminal subcommands for quick diagnostics without the menubar: `Hearth
/// status` and `Hearth logs`. Status prefers the control endpoint (the full
/// picture: phase, restarts, metrics, models) and falls back to a direct probe
/// when control is off. Logs tails the runner log.
enum StatusCLI {
    static func printUsage() {
        print("""
        Hearth: a background supervisor that keeps a local LLM runner alive.

        Usage:
          Hearth                    Run as a menubar agent (default).
          Hearth --headless         Run headless (no GUI), for a LaunchDaemon.
          Hearth status             Print the current supervision status.
          Hearth logs [-n N] [-f]   Show the runner log (last N lines; -f to follow).
          Hearth --help             Show this help.

        Status reads the config at HEARTH_CONFIG or the standard location and uses
        the control endpoint when it is enabled; otherwise it does a reduced probe.
        """)
    }

    // MARK: - status

    static func printStatus() -> Never {
        let config = ConfigStore.load().config

        if config.controlEnabled, let token = config.controlToken, !token.isEmpty {
            let url = URL(string: "http://\(config.controlHost):\(config.controlPort)/status")!
            let (data, response, _) = syncGET(url, bearer: token, timeout: 3)
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                printControlStatus(object)
                exit(0)
            }
            FileHandle.standardError.write(Data(
                "Could not reach Hearth's control endpoint at \(config.controlHost):\(config.controlPort).\n".utf8))
        }

        printReducedStatus(config: config)
        exit(0)
    }

    private static func printControlStatus(_ s: [String: Any]) {
        print("Hearth status (via control endpoint)")
        if let phase = s["phase"] as? String { print(row("phase", phase)) }
        if let up = s["uptimeSeconds"] as? Int { print(row("uptime", humanDuration(up))) }
        if let rc = s["restartCount"] as? Int { print(row("restarts", String(rc))) }
        if let cf = s["consecutiveFailures"] as? Int { print(row("failures", String(cf))) }
        if let models = s["models"] as? [String], !models.isEmpty {
            print(row("models", models.joined(separator: ", ")))
        } else {
            print(row("models", "none resident"))
        }
        if let pct = s["memoryUsedPercent"] as? Int { print(row("memory used", "\(pct)%")) }
        if let thermal = s["thermal"] as? String { print(row("thermal", thermal)) }
        if let rss = s["runnerResidentBytes"] as? Int { print(row("runner RSS", humanBytes(rss))) }
    }

    private static func printReducedStatus(config: HearthConfig) {
        print("Hearth status (reduced: control endpoint off or unreachable)")
        // Is the supervised runner from a recorded launch still alive?
        if let identity = recordedRunner(), kill(identity.pid, 0) == 0 {
            print(row("supervised pid", "\(identity.pid) (alive)"))
        } else {
            print(row("supervised pid", "none recorded"))
        }
        // Is anything actually listening on the runner's port?
        let base = URL(string: "http://\(config.host):\(config.port)/")!
        let (_, response, error) = syncGET(base, bearer: nil, timeout: 2)
        let serving = response != nil || !isConnectionRefused(error)
        print(row("runner \(config.host):\(config.port)", serving ? "serving" : "not serving"))
        print("")
        print("Enable the control endpoint (Preferences, or controlEnabled in the")
        print("config) for full status: phase, restarts, metrics, and resident models.")
    }

    private static func recordedRunner() -> RunnerProcessIdentity? {
        guard let data = try? Data(contentsOf: RunnerStateStore.url) else { return nil }
        return try? JSONDecoder().decode(RunnerProcessIdentity.self, from: data)
    }

    // MARK: - logs

    static func tailLogs(_ args: [String]) -> Never {
        let file = AppPaths.runnerLogFile.path
        guard FileManager.default.fileExists(atPath: file) else {
            FileHandle.standardError.write(Data("No runner log yet at \(file)\n".utf8))
            exit(1)
        }

        var lines = "50"
        var follow = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-f", "--follow": follow = true
            case "-n", "--lines":
                if i + 1 < args.count { lines = args[i + 1]; i += 1 }
            default: break
            }
            i += 1
        }

        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = (follow ? ["-f"] : []) + ["-n", lines, file]
        do {
            try tail.run()
            tail.waitUntilExit()
            exit(tail.terminationStatus)
        } catch {
            FileHandle.standardError.write(Data("Could not read \(file): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - helpers

    private static func row(_ label: String, _ value: String) -> String {
        let width = 16
        guard label.count < width else { return "  \(label)  \(value)" }
        let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
        return "  \(padded)\(value)"
    }

    private static func humanDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private static func humanBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private static func isConnectionRefused(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == NSURLErrorDomain
            && [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(error.code)
    }

    private static func syncGET(_ url: URL, bearer: String?, timeout: TimeInterval) -> (Data?, URLResponse?, Error?) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return result
    }
}
