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
        case .wedged: return "wedged (alive but not answering)"
        case .crashed(let reason): return reason.label
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
    /// Came back to healthy after having been unhealthy.
    case recovered
    /// Crash loop tripped; entered the failing phase.
    case enteredFailing(restartsInWindow: Int, window: TimeInterval)
    /// Resident models changed.
    case modelsUpdated([ResidentModel])
    /// Supervision stopped by request.
    case stopped

    /// Whether this transition is worth a push notification. Notifications fire on
    /// down, recovered, and failing, per the design.
    public var isNotable: Bool {
        switch self {
        case .down, .recovered, .enteredFailing:
            return true
        default:
            return false
        }
    }
}
