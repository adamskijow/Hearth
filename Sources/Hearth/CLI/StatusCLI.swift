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
          Hearth events [-n N] [-f] Show Hearth's own event history (down, restart, recovered).
          Hearth metrics            Show memory and thermal history over the retained window.
          Hearth doctor             Check the config and environment for problems.
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
                printRecentEvents()
                exit(0)
            }
            FileHandle.standardError.write(Data(
                "Could not reach Hearth's control endpoint at \(config.controlHost):\(config.controlPort).\n".utf8))
        }

        printReducedStatus(config: config)
        printRecentEvents()
        exit(0)
    }

    /// The tail of the persisted event log, which survives a Hearth restart.
    private static func printRecentEvents() {
        let recent = EventLogStore.recent(6)
        guard !recent.isEmpty else { return }
        print("")
        print("Recent activity:")
        for line in recent { print("  \(line)") }
    }

    private static func printControlStatus(_ s: [String: Any]) {
        print("Hearth status (via control endpoint)")
        if let phase = s["phase"] as? String { print(row("phase", phase)) }
        if let up = s["uptimeSeconds"] as? Int { print(row("uptime", StatusText.duration(Double(up)))) }
        if let rc = s["restartCount"] as? Int { print(row("restarts", String(rc))) }
        if let cf = s["consecutiveFailures"] as? Int { print(row("failures", String(cf))) }
        if let models = s["models"] as? [String], !models.isEmpty {
            print(row("models", models.joined(separator: ", ")))
        } else {
            print(row("models", "none resident"))
        }
        if let pct = s["memoryUsedPercent"] as? Int { print(row("memory used", "\(pct)%")) }
        if let thermal = s["thermal"] as? String { print(row("thermal", thermal)) }
        if let rss = s["runnerResidentBytes"] as? Int { print(row("runner RSS", StatusText.byteString(Int64(rss)))) }
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
        let serving = isSomethingListening(host: config.host, port: config.port)
        print(row("runner \(config.host):\(config.port)", serving ? "serving" : "not serving"))
        print("")
        print("Enable the control endpoint (Preferences, or controlEnabled in the")
        print("config) for full status: phase, restarts, metrics, and resident models.")
    }

    // MARK: - doctor

    static func printDoctor() -> Never {
        print("Hearth doctor")
        let load = ConfigStore.load()
        if load.isProblem {
            print(mark(.error) + " config: \(load.note ?? "could not be read")")
            print("\n1 error, 0 warnings.")
            exit(1)
        }
        if load.createdDefault, let note = load.note {
            print("  " + note)
        }
        let config = load.config

        var errors = 0, warnings = 0
        func report(_ diagnostic: Diagnostic) {
            print(mark(diagnostic.severity) + " " + diagnostic.message)
            if diagnostic.severity == .error { errors += 1 } else { warnings += 1 }
        }

        // Pure config rules.
        for diagnostic in ConfigDiagnostics.check(config) { report(diagnostic) }

        // Runner binary present and executable?
        let binary = runnerBinaryPath(config)
        if FileManager.default.isExecutableFile(atPath: binary) {
            print(mark(nil) + " runner binary: \(binary)")
        } else if let detected = RunnerLocator.locate(config.runner) {
            report(Diagnostic(.warning, "Runner binary not at \(binary); detected \(detected). Set it in Preferences or the config."))
        } else {
            report(Diagnostic(.error, "Runner binary not found at \(binary), and none detected in the usual locations or on PATH."))
        }

        // Runner port: free for a managed runner, or already serving for attached.
        let serving = isSomethingListening(host: config.host, port: config.port)
        if config.isManaged {
            if !serving {
                print(mark(nil) + " runner port \(config.host):\(config.port) is free")
            } else if let identity = recordedRunner(), kill(identity.pid, 0) == 0 {
                print(mark(nil) + " runner port \(config.host):\(config.port) served by Hearth's runner (pid \(identity.pid))")
            } else {
                report(Diagnostic(.warning, "Something other than Hearth's runner is listening on \(config.host):\(config.port); a managed runner may fail to bind."))
            }
        } else if serving {
            print(mark(nil) + " attached target is serving on \(config.host):\(config.port)")
        } else {
            report(Diagnostic(.warning, "Attached mode, but nothing is serving on \(config.host):\(config.port) yet."))
        }

        // Log directory writable?
        if directoryIsWritable(AppPaths.logDirectory) {
            print(mark(nil) + " log directory writable: \(AppPaths.logDirectory.path)")
        } else {
            report(Diagnostic(.warning, "Log directory \(AppPaths.logDirectory.path) is not writable; runner logs will be lost."))
        }

        print("")
        print("\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s").")
        exit(errors == 0 ? 0 : 1)
    }

    private static func mark(_ severity: Diagnostic.Severity?) -> String {
        switch severity {
        case .error: return "  FAIL"
        case .warning: return "  WARN"
        case nil: return "  OK  "
        }
    }

    private static func runnerBinaryPath(_ config: HearthConfig) -> String {
        switch config.runner.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio": return config.lmStudioBinaryPath
        case "mlx", "mlx_lm", "mlx-lm": return config.mlxBinaryPath
        default: return config.ollamaBinaryPath
        }
    }

    private static func isSomethingListening(host: String, port: Int) -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/") else { return false }
        let (_, response, error) = syncGET(url, bearer: nil, timeout: 2)
        return response != nil || !isConnectionRefused(error)
    }

    private static func directoryIsWritable(_ url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return fm.isWritableFile(atPath: url.path)
    }

    private static func recordedRunner() -> RunnerProcessIdentity? {
        guard let data = try? Data(contentsOf: RunnerStateStore.url) else { return nil }
        return try? JSONDecoder().decode(RunnerProcessIdentity.self, from: data)
    }

    // MARK: - metrics

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    static func printMetrics() -> Never {
        let history = MetricsHistoryStore.load()
        guard let summary = history.summary() else {
            print("No metrics history yet. While running, Hearth records a sample about once a minute.")
            exit(0)
        }
        print("Hearth metrics history")
        let span = summary.last.timeIntervalSince(summary.first)
        print(row("window", "\(stamp.string(from: summary.first)) to \(stamp.string(from: summary.last))  (\(StatusText.duration(span)), \(summary.count) samples)"))
        if let current = summary.currentMemoryPercent { print(row("memory now", "\(current)%")) }
        if let average = summary.averageMemoryPercent { print(row("memory avg", "\(average)%")) }
        if let peak = summary.peakMemoryPercent { print(row("memory peak", "\(peak)% (\(summary.memoryTrend.rawValue))")) }
        let sparkline = history.memorySparkline(width: 48)
        if !sparkline.isEmpty { print(row("memory", sparkline)) }
        if let rss = summary.peakRunnerResidentBytes { print(row("runner peak RSS", StatusText.byteString(rss))) }
        let thermals = summary.thermalCounts.sorted { $0.value > $1.value }
            .map { "\($0.key) \(Int((Double($0.value) / Double(summary.count) * 100).rounded()))%" }
            .joined(separator: ", ")
        if !thermals.isEmpty { print(row("thermal", thermals)) }
        exit(0)
    }

    // MARK: - logs and events

    static func tailLogs(_ args: [String]) -> Never {
        tailFile(AppPaths.runnerLogFile.path, missing: "No runner log yet", args)
    }

    static func tailEvents(_ args: [String]) -> Never {
        tailFile(EventLogStore.url.path, missing: "No events recorded yet", args)
    }

    private static func tailFile(_ file: String, missing: String, _ args: [String]) -> Never {
        guard FileManager.default.fileExists(atPath: file) else {
            FileHandle.standardError.write(Data("\(missing) at \(file)\n".utf8))
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

    private static func isConnectionRefused(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == NSURLErrorDomain
            && [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(error.code)
    }

    /// A reference box so the URLSession completion can store its result without
    /// the compiler flagging a captured-var mutation; the semaphore serializes the
    /// write and the read.
    private final class ResultBox: @unchecked Sendable {
        var value: (Data?, URLResponse?, Error?) = (nil, nil, nil)
    }

    private static func syncGET(_ url: URL, bearer: String?, timeout: TimeInterval) -> (Data?, URLResponse?, Error?) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.value = (data, response, error)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return box.value
    }
}
