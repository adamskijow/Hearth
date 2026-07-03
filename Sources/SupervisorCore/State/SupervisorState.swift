// SPDX-License-Identifier: MIT

import Foundation

/// The supervisor's lifecycle phase. The four phases named in the design,
/// Healthy, Down, Restarting, and Failing, are the heart of the restart policy;
/// Stopped and Starting are the honest bookends around them.
public enum SupervisorPhase: String, Sendable, Equatable {
    /// Not supervising. No child owned.
    case stopped
    /// A child was spawned and we are waiting for its first readiness, inside the
    /// startup grace period.
    case starting
    /// Alive and ready. Serving.
    case healthy
    /// A failure was detected and we are waiting out the normal backoff before
    /// the next respawn.
    case down
    /// Backoff elapsed; a fresh child was spawned and we are waiting for it to
    /// become ready again.
    case restarting
    /// Crash loop tripped. We stop thrashing and retry on a slow cadence.
    case failing

    /// Whether the supervisor intends to keep a child alive in this phase. Used
    /// to decide when the sleep preventing power assertion should be held.
    public var isSupervising: Bool {
        self != .stopped
    }
}

/// The typed snapshot the menubar renders. Plain data, `Sendable`, `Equatable`,
/// with no behavior. The core publishes it; it never reaches back into the UI.
public struct SupervisorState: Sendable, Equatable {
    public var phase: SupervisorPhase
    /// Models the runner currently holds resident, from its own API.
    public var residentModels: [ResidentModel]
    /// When the current healthy streak began, for uptime. Nil while not healthy.
    public var healthySince: Date?
    /// A short description of the most recent restart's cause, for the menubar.
    public var lastRestartReason: String?
    /// Total respawns performed since the last fresh start.
    public var restartCount: Int
    /// Consecutive failures since the last recovery. Drives backoff.
    public var consecutiveFailures: Int
    /// When the supervisor entered the failing phase, if it is failing.
    public var failingSince: Date?
    /// Whether the current failure streak included a real process exit, not only
    /// "alive but not answering" wedges. Drives the opt-in reboot policy that
    /// refuses to reboot for a runner-forgeable wedge.
    public var failingStreakHadProcessExit: Bool
    /// When the next respawn is scheduled, while down or failing.
    public var nextRetryAt: Date?
    /// When the phase last changed.
    public var lastTransition: Date
    /// Whether the last probe answered busy (a full queue): healthy and working,
    /// but a new request would wait.
    public var busy: Bool
    /// Bounded category of the most recent failure (wedged, crash, oom, signal),
    /// for metrics labels. Nil until something has failed this session.
    public var lastDownCategory: String?
    /// Bounded category of the most recent restart, covering deliberate restarts
    /// too (adds memory-limit, maintenance, manual, binary-upgrade). Nil until
    /// the first restart this session.
    public var lastRestartCategory: String?
    /// Whether the optional deep readiness probe is configured.
    public var deepProbeConfigured: Bool
    /// When the deep probe last failed, if it ever has this session.
    public var deepProbeLastFailedAt: Date?

    public init(phase: SupervisorPhase = .stopped,
                residentModels: [ResidentModel] = [],
                healthySince: Date? = nil,
                lastRestartReason: String? = nil,
                restartCount: Int = 0,
                consecutiveFailures: Int = 0,
                failingSince: Date? = nil,
                nextRetryAt: Date? = nil,
                lastTransition: Date = Date(timeIntervalSince1970: 0),
                failingStreakHadProcessExit: Bool = false,
                busy: Bool = false,
                lastDownCategory: String? = nil,
                lastRestartCategory: String? = nil,
                deepProbeConfigured: Bool = false,
                deepProbeLastFailedAt: Date? = nil) {
        self.phase = phase
        self.residentModels = residentModels
        self.healthySince = healthySince
        self.lastRestartReason = lastRestartReason
        self.restartCount = restartCount
        self.consecutiveFailures = consecutiveFailures
        self.failingSince = failingSince
        self.nextRetryAt = nextRetryAt
        self.lastTransition = lastTransition
        self.failingStreakHadProcessExit = failingStreakHadProcessExit
        self.busy = busy
        self.lastDownCategory = lastDownCategory
        self.lastRestartCategory = lastRestartCategory
        self.deepProbeConfigured = deepProbeConfigured
        self.deepProbeLastFailedAt = deepProbeLastFailedAt
    }

    /// Uptime of the current healthy streak as of `reference`. Nil if not
    /// currently healthy.
    public func uptime(asOf reference: Date) -> TimeInterval? {
        guard let healthySince else { return nil }
        return reference.timeIntervalSince(healthySince)
    }
}
