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
          Hearth status [--json]    Print the current supervision status (--json for agents).
          Hearth logs [-n N] [-f]   Show the runner log (last N lines; -f to follow).
          Hearth events [-n N] [-f] Show Hearth's own event history (down, restart, recovered).
          Hearth metrics            Show memory and thermal history over the retained window.
          Hearth doctor             Check the config and environment for problems.
          Hearth doctor-daemon      Check the root daemon config at /etc/hearth/config.json.
          Hearth mode managed|attached [--daemon] [--force]
                                    Set whether Hearth starts the runner or watches one.
          Hearth setup              Turnkey: detect the runner, install the login agent, wait for ready.
          Hearth wait-ready [-t S]  Block until the runner answers (exit 0), or time out (exit 1).
          Hearth install-agent      Install a login agent that keeps Hearth running (no sudo).
          Hearth uninstall-agent    Remove that login agent.
          Hearth --help             Show this help.

        Status reads the config at HEARTH_CONFIG or the standard location and uses
        the control endpoint when it is enabled; otherwise it does a reduced probe.
        An app that depends on a local runner can gate its startup on `wait-ready`
        and ensure supervision with `install-agent`; see docs/integrating.md.
        """)
    }

    // MARK: - status

    static func printStatus(_ args: [String] = []) -> Never {
        let json = args.contains("--json")
        let config = ConfigStore.load().config

        // Bracket an IPv6 control host (::1, a Tailscale fd7a:... address) the
        // same way every other URL builder does; a bare literal makes URL(string:)
        // nil and this is a user-facing command, so fall back to the reduced
        // status rather than trapping.
        if config.controlEnabled, let token = config.controlToken, !token.isEmpty,
           let url = URL(string: "http://\(urlAuthorityHost(for: config.controlHost)):\(config.controlPort)/status") {
            let (data, response, _) = syncGET(url, bearer: token, timeout: 3)
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json {
                    emitStatusJSON(control: object)
                } else {
                    printControlStatus(object)
                    printRecentEvents()
                }
                exit(0)
            }
            if !json {
                FileHandle.standardError.write(Data(
                    "Hearth: could not reach the control endpoint at \(config.controlHost):\(config.controlPort).\n".utf8))
            }
        }

        if json {
            emitReducedJSON(config: config)
        } else {
            printReducedStatus(config: config)
            printRecentEvents()
        }
        exit(0)
    }

    /// Machine-readable status, for an agent verifying a setup. `healthy` is the
    /// one field a script usually wants. Source is "control" (full picture) or
    /// "reduced" (control endpoint off or unreachable).
    private static func emitStatusJSON(control s: [String: Any]) {
        var out = s
        out["source"] = "control"
        out["supervising"] = true
        out["healthy"] = (s["phase"] as? String) == "healthy"
        out["recentEvents"] = EventLogStore.recent(6)
        emitJSON(out)
    }

    private static func emitReducedJSON(config: HearthConfig) {
        let serving = isSomethingListening(host: config.host, port: config.port)
        var out: [String: Any] = [
            "source": "reduced",
            "controlEndpoint": config.controlEnabled ? "unreachable" : "off",
            "runner": config.runner,
            "runnerHost": config.host,
            "runnerPort": config.port,
            "runnerServing": serving,
            "healthy": serving,
            "recentEvents": EventLogStore.recent(6),
        ]
        if let identity = recordedRunner(), kill(identity.pid, 0) == 0 {
            out["supervisedPid"] = Int(identity.pid)
        }
        emitJSON(out)
    }

    private static func emitJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
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

    // MARK: - wait-ready

    /// Block until the runner answers its readiness endpoint, then exit 0; exit 1
    /// on timeout. Lets a dependent app gate its startup on the runner being up
    /// (`hearth wait-ready && start-my-app`) without reinventing a retry loop. It
    /// probes the runner directly, so it does not require Hearth itself to be up,
    /// only the runner Hearth keeps alive.
    static func waitReady(_ args: [String]) -> Never {
        var timeout = 120.0
        var i = 0
        while i < args.count {
            if args[i] == "-t" || args[i] == "--timeout", i + 1 < args.count, let value = Double(args[i + 1]) {
                timeout = value
                i += 1
            }
            i += 1
        }

        let config = ConfigStore.load().config
        if isRunnerReady(config: config, timeout: timeout) { exit(0) }
        FileHandle.standardError.write(Data(
            "Hearth: runner at \(config.host):\(config.port) was not ready within \(Int(timeout))s.\n".utf8))
        exit(1)
    }

    /// Poll the runner's readiness endpoint until it answers (200) or the timeout
    /// elapses. Shared by `wait-ready` and `setup`.
    static func isRunnerReady(config: HearthConfig, timeout: TimeInterval) -> Bool {
        let url = config.makeRunner().readinessEndpoint
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let (_, response, _) = syncGET(url, bearer: nil, timeout: 3)
            if (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

    struct RunnerPortProbe {
        var portOccupied: Bool
        var compatibleRunnerReady: Bool
        var hearthRunner: RunnerProcessIdentity?
    }

    static func probeRunnerPort(config: HearthConfig) -> RunnerPortProbe {
        RunnerPortProbe(
            portOccupied: isSomethingListening(host: config.host, port: config.port),
            compatibleRunnerReady: isRunnerReady(config: config, timeout: 1),
            hearthRunner: liveRecordedRunner()
        )
    }

    // MARK: - doctor

    static func printDoctor() -> Never {
        printDoctor(configURL: AppPaths.configFile, runningAsRoot: geteuid() == 0, includeDaemonHint: true)
    }

    static func printDaemonDoctor() -> Never {
        let daemonConfig = URL(fileURLWithPath: "/etc/hearth/config.json")
        if geteuid() != 0 {
            print("Hearth daemon doctor")
            print(mark(.error) + " daemon config is root-owned; run this check with sudo:")
            print("       sudo hearth doctor-daemon")
            exit(1)
        }
        guard FileManager.default.fileExists(atPath: daemonConfig.path) else {
            print("Hearth daemon doctor")
            print(mark(.error) + " daemon config not found at \(daemonConfig.path)")
            print("")
            print("Install the root daemon first with: sudo ./scripts/install-daemon.sh")
            exit(1)
        }
        printDoctor(configURL: daemonConfig, runningAsRoot: true, includeDaemonHint: false, title: "Hearth daemon doctor")
    }

    private static func printDoctor(configURL: URL,
                                    runningAsRoot: Bool,
                                    includeDaemonHint: Bool,
                                    title: String = "Hearth doctor") -> Never {
        print(title)
        let load = ConfigStore.load(from: configURL, createDefaultIfMissing: includeDaemonHint)
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
        for diagnostic in ConfigDiagnostics.check(config, runningAsRoot: runningAsRoot) { report(diagnostic) }
        if includeDaemonHint, daemonAppearsInstalled(), ProcessInfo.processInfo.environment["HEARTH_CONFIG"] == nil {
            report(Diagnostic(.warning, "A root daemon appears installed. This doctor is checking \(configURL.path); check the daemon config with `sudo hearth doctor-daemon`."))
        }

        // Runner binary present and executable?
        let binary = config.selectedBinaryPath
        if FileManager.default.isExecutableFile(atPath: binary) {
            print(mark(nil) + " runner binary: \(binary)")
        } else if let detected = RunnerLocator.locate(config.runner) {
            report(Diagnostic(.warning, "Runner binary not at \(binary); detected \(detected). Set it in Preferences or the config."))
        } else {
            report(Diagnostic(.error, "Runner binary not found at \(binary), and none detected in the usual locations or on PATH."))
        }

        // Runner port: free for a managed runner, or already serving for attached.
        let runnerPort = probeRunnerPort(config: config)
        if config.isManaged {
            if !runnerPort.portOccupied {
                print(mark(nil) + " runner port \(config.host):\(config.port) is free")
            } else if let identity = runnerPort.hearthRunner {
                print(mark(nil) + " runner port \(config.host):\(config.port) served by Hearth's runner (pid \(identity.pid))")
            } else if runnerPort.compatibleRunnerReady {
                report(Diagnostic(.warning, PreexistingRunner.warning(
                    runner: config.runner, mode: config.mode, foreignRunnerServing: true)
                    ?? "A compatible runner is already serving on \(config.host):\(config.port)."))
            } else {
                report(Diagnostic(.warning, PreexistingRunner.unknownListenerWarning(
                    runner: config.runner, host: config.host, port: config.port)))
            }
        } else if runnerPort.compatibleRunnerReady {
            print(mark(nil) + " attached target is serving on \(config.host):\(config.port)")
        } else {
            report(Diagnostic(.warning, PreexistingRunner.attachedMissingWarning(
                runner: config.runner,
                host: config.host,
                port: config.port,
                listenerPresent: runnerPort.portOccupied)))
        }

        // Reachability: can another machine on the network reach the runner, or is
        // it loopback-only? Loopback-only is the default and correct for a single
        // machine, so this is informational guidance, not a warning.
        let reachAddress = NetworkInterfaces.lanIPv4() ?? NetworkInterfaces.tailnetIPv4()
        if RunnerReachability.isLoopbackOnly(host: config.host) {
            print(mark(nil) + " runner bound to \(config.host) (reachable only from this Mac)")
            let dest = reachAddress ?? "this-mac-ip"
            print("       to reach it from another computer: set host to 0.0.0.0, open the firewall for port \(config.port), then connect to http://\(dest):\(config.port)")
        } else if let url = RunnerReachability.url(host: config.host, port: config.port, resolvedAddress: reachAddress) {
            print(mark(nil) + " runner reachable from your network at \(url)")
        } else {
            print(mark(nil) + " runner bound to \(config.host) (open to the network), but no LAN or tailnet address was found to advertise")
        }

        // Another manager (brew services) keeping the same runner alive?
        if let conflict = RunnerManagerConflict.warning(
            runner: config.runner, mode: config.mode, loadedLabels: LaunchdLabels.loaded()) {
            report(Diagnostic(.warning, conflict))
        } else if config.isManaged {
            print(mark(nil) + " no competing manager for \(config.runner) (brew services etc.)")
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

    private static func daemonAppearsInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.hearth.daemon.plist")
    }

    private static func mark(_ severity: Diagnostic.Severity?) -> String {
        switch severity {
        case .error: return "  FAIL"
        case .warning: return "  WARN"
        case nil: return "  OK  "
        }
    }

    private static func isSomethingListening(host: String, port: Int) -> Bool {
        // The shared wildcard-to-loopback mapping the probe URLs use, so this
        // port check and the readiness probe agree about where to dial.
        let target = probeHost(for: host)

        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target, String(port), &hints, &result) == 0, let result else {
            return false
        }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let connected = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
                close(fd)
                if connected { return true }
            }
            cursor = info.pointee.ai_next
        }
        return false
    }

    private static func directoryIsWritable(_ url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return fm.isWritableFile(atPath: url.path)
    }

    /// The most recently recorded runner (the store keeps a predecessor around
    /// while its teardown is still in flight; the newest entry is the current one).
    private static func recordedRunner() -> RunnerProcessIdentity? {
        RunnerStateStore.loadRecorded().last
    }

    /// The newest recorded runner that is still the same live instance.
    private static func liveRecordedRunner() -> RunnerProcessIdentity? {
        for recorded in RunnerStateStore.loadRecorded().reversed() {
            guard let live = RunnerStateStore.liveIdentity(pid: recorded.pid),
                  RunnerSweep.shouldSweep(recorded: recorded, live: live),
                  kill(recorded.pid, 0) == 0 else { continue }
            return recorded
        }
        return nil
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
        let completed = semaphore.wait(timeout: .now() + timeout + 1) == .success
        if !completed {
            task.cancel()
            return (nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        }
        return box.value
    }
}
