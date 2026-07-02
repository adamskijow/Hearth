// SPDX-License-Identifier: MIT

import Foundation

/// Why the runner is considered not serving.
public enum DownReason: Sendable, Equatable {
    /// Alive but not answering its readiness endpoint in time. The zombie a PID
    /// check misses.
    case wedged
    /// The process exited, with the classified reason.
    case crashed(ExitReason)

    public var label: String {
        switch self {
        case .wedged: return "stuck (still running, but not answering)"
        case .crashed(let reason): return reason.label
        }
    }

    /// A bounded, low-cardinality category for metrics labels. Never model
    /// names, paths, or stderr content; only these fixed values.
    public var category: String {
        switch self {
        case .wedged: return "wedged"
        case .crashed(let reason):
            switch reason {
            case .outOfMemory: return "oom"
            case .signal: return "signal"
            case .crash: return "crash"
            case .cleanExit: return "clean-exit"
            case .running, .unknown: return "unknown"
            }
        }
    }
}

/// Discrete things that happen, as opposed to the continuous `SupervisorState`.
/// The UI logs these; the engine turns the notable ones into notifications.
public enum SupervisorEvent: Sendable, Equatable {
    /// A fresh supervision session began.
    case started
    /// Became healthy for the first time this session.
    case becameHealthy
    /// Detected not serving. Carries the cause.
    case down(DownReason)
    /// A scheduled normal backoff restart is pending.
    case restartScheduled(attempt: Int, backoff: TimeInterval)
    /// A respawn was just issued.
    case restarted(attempt: Int)
    /// A scheduled maintenance restart was issued to clear the memory creep that
    /// degrades a long-running runner. Routine, so it is logged but not pushed.
    case maintenanceRestart
    /// Came back to healthy after having been unhealthy.
    case recovered
    /// Crash loop tripped; entered the failing phase.
    case enteredFailing(restartsInWindow: Int, window: TimeInterval)
    /// Resident models changed.
    case modelsUpdated([ResidentModel])
    /// The post-restart model warm-up finished. `missing` lists models that were
    /// resident before the restart but could not be loaded again.
    case warmupFinished(missing: [String])
    /// The opt-in memory watchdog restarted the runner: its resident size
    /// crossed the configured ceiling.
    case memoryLimitExceeded(residentBytes: Int64, limitBytes: Int64)
    /// Supervision stopped by request.
    case stopped

    /// Whether this transition is worth a push notification. Notifications fire on
    /// down, recovered, failing, and a warm-up that could not restore a model.
    public var isNotable: Bool {
        switch self {
        case .down, .recovered, .enteredFailing:
            return true
        case .warmupFinished(let missing):
            return !missing.isEmpty
        case .memoryLimitExceeded:
            return true
        default:
            return false
        }
    }
}
