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
    private static let knownRunners = ["ollama", "lmstudio", "lm-studio", "lm_studio", "mlx", "mlx_lm", "mlx-lm"]

    public static func check(_ config: HearthConfig) -> [Diagnostic] {
        var issues: [Diagnostic] = []

        if config.host.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(.error, "Host is empty."))
        } else if URL(string: "http://\(config.host):\(config.port)/") == nil {
            issues.append(.init(.error, "Host \"\(config.host)\" is not a valid hostname or address."))
        }
        if !isValidPort(config.port) {
            issues.append(.init(.error, "Runner port \(config.port) is out of range (1-65535)."))
        }
        if !knownRunners.contains(config.runner.lowercased()) {
            issues.append(.init(.error, "Unknown runner \"\(config.runner)\"; expected ollama, lmstudio, or mlx."))
        }
        let mode = config.mode.lowercased()
        if mode != "managed" && mode != "attached" {
            issues.append(.init(.error, "Unknown mode \"\(config.mode)\"; expected managed or attached."))
        }
        // LM Studio's `lms server start` exits immediately (the server runs in LM
        // Studio's own background process), so a managed runner thrashes. Use
        // attached mode and start the LM Studio server yourself.
        if ["lmstudio", "lm-studio", "lm_studio"].contains(config.runner.lowercased()), mode == "managed" {
            issues.append(.init(.warning, "LM Studio works only in attached mode; `lms server start` exits at once, so managed mode thrashes. Set mode to attached and start LM Studio's server yourself."))
        }
        // Hearth derives OLLAMA_HOST from host and port, so a runnerEnv value for it
        // is overwritten at spawn; flag it rather than letting it silently lose.
        // Anything that is not LM Studio or mlx runs as Ollama (the default path).
        let isLMStudio = ["lmstudio", "lm-studio", "lm_studio"].contains(config.runner.lowercased())
        let isMLX = ["mlx", "mlx_lm", "mlx-lm"].contains(config.runner.lowercased())
        let isOllama = !isLMStudio && !isMLX
        if isOllama, config.runnerEnv.keys.contains("OLLAMA_HOST") {
            issues.append(.init(.warning, "runnerEnv sets OLLAMA_HOST, but Hearth derives it from host and port; the runnerEnv value is ignored. Set host instead to change the bind address."))
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

        if let topic = config.ntfyTopic, topic.localizedCaseInsensitiveContains("CHANGE-ME") {
            issues.append(.init(.warning, "ntfyTopic is still the placeholder; status would post to a guessable public topic. Set a long, unguessable topic, or null to disable ntfy."))
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
        if config.maxBackoffSeconds < config.initialBackoffSeconds {
            issues.append(.init(.warning, "Max backoff is less than the initial backoff, so backoff cannot grow."))
        }
        if config.crashLoopThreshold < 1 {
            issues.append(.init(.warning, "Crash loop threshold below 1 trips the crash-loop brake immediately."))
        }
        if config.rebootOnWedge {
            issues.append(.init(.warning, "Reboot escalation (rebootOnWedge) only takes effect when Hearth runs as root, the headless LaunchDaemon; it is a no-op in the menubar app."))
        }

        return issues
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }
}
