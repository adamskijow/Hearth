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

        if config.controlEnabled {
            if (config.controlToken ?? "").isEmpty {
                issues.append(.init(.error, "Control endpoint is enabled but has no token; it will refuse to start."))
            }
            if !isValidPort(config.controlPort) {
                issues.append(.init(.error, "Control port \(config.controlPort) is out of range (1-65535)."))
            }
            if config.controlPort == config.port {
                issues.append(.init(.error, "Control port and runner port are both \(config.port); they must differ."))
            }
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

        return issues
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }
}
