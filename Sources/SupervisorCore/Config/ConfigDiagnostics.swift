// SPDX-License-Identifier: MIT

import Foundation

/// One problem found in a config, with how serious it is. Errors will stop the
/// runner from being supervised correctly; warnings are setups that work but are
/// probably not what you meant.
public struct Diagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case warning
        case error
    }

    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Pure validation of a `HearthConfig`. The same rules back the `hearth doctor`
/// command and could back an in-app check; keeping them here makes every rule
/// testable without a filesystem or a running app.
public enum ConfigDiagnostics {

    public static func check(_ config: HearthConfig, runningAsRoot: Bool = false) -> [Diagnostic] {
        var issues: [Diagnostic] = []

        let host = config.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            issues.append(.init(.error, "Host is empty."))
        } else {
            if host == "0.0.0.0" || host == "::" {
                issues.append(.init(.warning, "Runner is bound to \(host) (all interfaces). Ollama has no built-in authentication; use this only on a trusted LAN or behind a private reverse proxy."))
            }
            // Bracket an IPv6 literal the same way the probe endpoints do, so a
            // host like ::1 that supervision handles fine is not flagged invalid.
            if URL(string: "http://\(urlAuthorityHost(for: config.host)):\(config.port)/") == nil {
                issues.append(.init(.error, "Host \"\(config.host)\" is not a valid hostname or address."))
            }
        }
        if !isValidPort(config.port) {
            issues.append(.init(.error, "Runner port \(config.port) is out of range (1-65535)."))
        }
        if !RunnerKind.knownConfigStrings.contains(config.runner.lowercased()) {
            issues.append(.init(.error, "Unknown runner \"\(config.runner)\"; expected ollama, lmstudio, mlx, or osaurus."))
        }
        let mode = config.mode.lowercased()
        if !ModeKind.knownConfigStrings.contains(mode) {
            issues.append(.init(.error, "Unknown mode \"\(config.mode)\"; expected managed or attached."))
        }
        // LM Studio's `lms server start` exits immediately (the server runs in LM
        // Studio's own background process), so a managed runner thrashes. Use
        // attached mode and start the LM Studio server yourself.
        if config.runnerKind == .lmStudio, mode == "managed" {
            issues.append(.init(.warning, "LM Studio works only in attached mode; `lms server start` exits at once, so managed mode thrashes. Set mode to attached and start LM Studio's server yourself."))
        }
        if config.runnerKind == .lmStudio, config.port == 11434 {
            issues.append(.init(.warning, "LM Studio usually serves on port 1234; this config still uses Ollama's default 11434. Set port to 1234 unless you changed LM Studio."))
        }
        if config.runnerKind == .mlx, config.port == 11434 {
            issues.append(.init(.warning, "mlx_lm.server usually serves on port 8080; this config still uses Ollama's default 11434. Set port to 8080 unless you changed mlx_lm."))
        }
        // Osaurus's CLI is the app binary and `osaurus serve` may hand the server
        // off rather than staying in the foreground; recommend attached, like LM
        // Studio, rather than letting managed mode thrash mysteriously.
        if config.runnerKind == .osaurus, mode == "managed" {
            issues.append(.init(.warning, "Managed mode with Osaurus is best effort: if it thrashes (down, restarting, down), start the server yourself with `osaurus serve` and use attached mode."))
        }
        if config.runnerKind == .osaurus, config.port == 11434 {
            issues.append(.init(.warning, "Osaurus usually serves on port 1337; this config still uses Ollama's default 11434. Set port to 1337 unless you changed Osaurus."))
        }
        // Hearth derives OLLAMA_HOST from host and port, so a runnerEnv value for it
        // is overwritten at spawn; flag it rather than letting it silently lose.
        if config.runnerKind == .ollama, config.runnerEnv.keys.contains("OLLAMA_HOST") {
            issues.append(.init(.warning, "runnerEnv sets OLLAMA_HOST, but Hearth derives it from host and port; the runnerEnv value is ignored. Set host instead to change the bind address."))
        }
        let runnerUser = config.normalizedRunnerUser
        if runningAsRoot, config.isManaged, let runnerUser {
            if let credentials = RunnerUserCredentials.resolve(username: runnerUser) {
                if credentials.isRoot {
                    issues.append(.init(.error, "runnerUser resolves to root; choose an unprivileged account so the root daemon does not run the LLM runner as root."))
                }
            } else {
                issues.append(.init(.error, "runnerUser \"\(runnerUser)\" does not resolve to an account; the root daemon will refuse to start the managed runner."))
            }
        } else if runningAsRoot && config.isManaged {
            issues.append(.init(.error, "Hearth is running as root in managed mode but runnerUser is unset; the root daemon refuses to start the LLM runner as root. Set runnerUser to an unprivileged account or use attached mode."))
        } else if !runningAsRoot && config.isManaged && config.rebootOnWedge && runnerUser == nil && !config.rebootViaHelper {
            issues.append(.init(.warning, "rebootOnWedge needs the root daemon, and managed root daemon mode requires runnerUser. Set runnerUser before enabling unattended reboot recovery (or use the experimental rebootViaHelper)."))
        }

        if config.controlEnabled {
            let token = config.controlToken ?? ""
            if token.isEmpty {
                issues.append(.init(.error, "Control endpoint is enabled but has no token; it will refuse to start."))
            } else if token.localizedCaseInsensitiveContains("CHANGE-ME") || token.count < 16 {
                issues.append(.init(.warning, "Control token is the placeholder or shorter than 16 characters; the start/stop/restart surface is only as strong as this token. Use a long, unguessable secret (Preferences has a Generate button)."))
            }
            if !isValidPort(config.controlPort) {
                issues.append(.init(.error, "Control port \(config.controlPort) is out of range (1-65535)."))
            }
            if config.controlPort == config.port {
                issues.append(.init(.error, "Control port and runner port are both \(config.port); they must differ."))
            }
            // 0.0.0.0 exposes the control surface on every interface, including any
            // public one; a specific private/Tailscale address is the intended bind.
            let controlHost = config.controlHost.trimmingCharacters(in: .whitespaces)
            if controlHost == "0.0.0.0" || controlHost == "::" {
                issues.append(.init(.warning, "Control endpoint is bound to \(controlHost) (all interfaces); its start/stop/restart surface is reachable from any network this Mac joins. Bind controlHost to 127.0.0.1 or a specific private (Tailscale) address."))
            }
        }

        // The log-tail opt-in sends runner content off the box; over the PUBLIC
        // ntfy.sh that content transits a third party. Say so, every doctor run.
        if config.alertsIncludeLogTail,
           let topic = config.ntfyTopic?.trimmingCharacters(in: .whitespaces), !topic.isEmpty,
           config.ntfyServer.localizedCaseInsensitiveContains("ntfy.sh") {
            issues.append(.init(.warning, "alertsIncludeLogTail sends runner log lines (paths, model names, possibly request content) through the public ntfy.sh server. Use a self-hosted ntfy server with this flag, or turn it off."))
        }
        if let topic = config.ntfyTopic, topic.localizedCaseInsensitiveContains("CHANGE-ME") {
            issues.append(.init(.warning, "ntfyTopic is still the placeholder; status would post to a guessable public topic. Set a long, unguessable topic, or null to disable ntfy."))
        } else if let topic = config.ntfyTopic?.trimmingCharacters(in: .whitespaces), !topic.isEmpty, topic.count < 16 {
            issues.append(.init(.warning, "ntfyTopic is shorter than 16 characters; public ntfy topics are bearer secrets, so use a long unguessable topic or a private ntfy server."))
        }

        if let webhook = config.webhookURL?.trimmingCharacters(in: .whitespaces), !webhook.isEmpty,
           let url = URL(string: webhook), url.scheme?.lowercased() != "https" {
            issues.append(.init(.warning, "webhookURL does not use HTTPS; Hearth posts status over this URL, so prefer HTTPS or a private loopback-only endpoint."))
        }

        if config.probeIntervalSeconds <= 0 {
            issues.append(.init(.warning, "Probe interval should be greater than 0; the runner will not be checked."))
        }
        if config.startupGraceSeconds <= 0 {
            issues.append(.init(.warning, "Startup grace should be greater than 0; the runner may be killed before it comes up."))
        }
        if config.backoffMultiplier < 1 {
            issues.append(.init(.warning, "Backoff multiplier below 1 shrinks the wait between restarts."))
        }
        if config.initialBackoffSeconds <= 0 {
            issues.append(.init(.warning, "Initial backoff should be greater than 0; failed restarts would respawn with no delay."))
        }
        if let window = config.maintenanceWindow?.trimmingCharacters(in: .whitespaces), !window.isEmpty,
           MaintenanceWindow.parse(window) == nil {
            issues.append(.init(.warning, "maintenanceWindow \"\(window)\" is not HH:MM-HH:MM (24-hour); scheduled maintenance restarts will ignore it and fire at any time."))
        }
        if let heartbeat = config.heartbeatURL?.trimmingCharacters(in: .whitespaces), !heartbeat.isEmpty {
            if let url = URL(string: heartbeat), let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https", url.host != nil {
                // Shape is fine.
            } else {
                issues.append(.init(.warning, "heartbeatURL \"\(heartbeat)\" is not an http(s) URL; heartbeats will not be sent."))
            }
        }
        if config.heartbeatIntervalSeconds < 10 {
            issues.append(.init(.warning, "heartbeatIntervalSeconds below 10 is clamped to 10; a monitor rarely needs a faster pulse."))
        }
        if config.runnerMemoryLimitMB > 0, config.runnerMemoryLimitMB < 512 {
            issues.append(.init(.warning, "runnerMemoryLimitMB \(config.runnerMemoryLimitMB) is smaller than almost any loaded model; the watchdog would restart the runner in a loop. Use a value above what your models need, or 0 to disable."))
        }
        if config.metricsProxyEnabled {
            if !isValidPort(config.metricsProxyPort) {
                issues.append(.init(.error, "Metrics proxy port \(config.metricsProxyPort) is out of range (1-65535)."))
            }
            if config.metricsProxyPort == config.port {
                issues.append(.init(.error, "Metrics proxy port and runner port are both \(config.port); they must differ."))
            }
            if config.controlEnabled, config.metricsProxyPort == config.controlPort {
                issues.append(.init(.error, "Metrics proxy port and control port are both \(config.controlPort); they must differ."))
            }
            if !config.controlEnabled {
                issues.append(.init(.warning, "metricsProxyEnabled without controlEnabled: throughput is collected but nothing serves /metrics. Enable the control endpoint to read it."))
            }
        }
        if config.drainSeconds > 0, !config.metricsProxyEnabled {
            issues.append(.init(.warning, "drainSeconds needs the metrics proxy (the only place in-flight work is observable); without metricsProxyEnabled routine restarts do not wait."))
        }
        if config.maxBackoffSeconds < config.initialBackoffSeconds {
            issues.append(.init(.warning, "Max backoff is less than the initial backoff, so backoff cannot grow."))
        }
        if config.crashLoopThreshold < 1 {
            issues.append(.init(.warning, "Crash loop threshold below 1 trips the crash-loop brake immediately."))
        }
        if config.rebootOnWedge && !runningAsRoot && !config.rebootViaHelper {
            issues.append(.init(.warning, "Reboot escalation (rebootOnWedge) only takes effect when Hearth runs as root, the headless LaunchDaemon; it is a no-op in the menubar app. The experimental rebootViaHelper lifts the root requirement for the headless daemon."))
        }

        return issues
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }
}
