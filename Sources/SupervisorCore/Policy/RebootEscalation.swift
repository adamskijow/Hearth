// SPDX-License-Identifier: MIT

import Foundation

/// The last rung of the recovery ladder. Killing and respawning the runner clears
/// a process-level wedge, but some hangs are at the driver or GPU level and only a
/// reboot of the Mac clears them. On a headless appliance, a human otherwise has
/// to notice and reboot it by hand. With this enabled, Hearth detects that
/// signature (still wedged long after process restarts stopped helping) and
/// reboots, then comes back and respawns the runner clean.
///
/// This is the scariest thing the supervisor can do, so the policy is paranoid:
/// opt-in, only after the runner was actually healthy this session, only after a
/// sustained failing streak, and hard-capped against a reboot loop.

/// How aggressive the reboot escalation is. Disabled by default.
public struct RebootPolicy: Sendable, Equatable {
    public var enabled: Bool
    /// How long the runner must stay in the failing (crash-loop) phase, with
    /// process restarts not restoring it, before a reboot is considered.
    public var escalateAfterSeconds: Double
    /// The minimum time between recovery reboots. If we rebooted more recently
    /// than this and are still wedged, the reboot did not help, so do not loop.
    public var minIntervalSeconds: Double
    /// The most recovery reboots allowed in a rolling 24 hours.
    public var maxPerDay: Int

    public init(enabled: Bool = false,
                escalateAfterSeconds: Double = 600,
                minIntervalSeconds: Double = 1800,
                maxPerDay: Int = 3) {
        self.enabled = enabled
        self.escalateAfterSeconds = escalateAfterSeconds
        self.minIntervalSeconds = minIntervalSeconds
        self.maxPerDay = maxPerDay
    }
}

/// The record of recovery reboots, persisted to disk so the loop guard survives
/// the reboots themselves.
public struct RebootHistory: Codable, Sendable, Equatable {
    public var recoveryReboots: [Date]

    public init(recoveryReboots: [Date] = []) {
        self.recoveryReboots = recoveryReboots
    }
}

public enum RebootDecision: Sendable, Equatable {
    /// Not yet: not failing long enough, or escalation is off, or never healthy.
    case wait
    /// Escalate now: reboot the machine.
    case reboot
    /// Would reboot, but the loop guard forbids it (a recent reboot did not help,
    /// or the daily cap is reached). A human needs to look.
    case exhausted
}

public enum RebootEscalation {
    public static func decide(policy: RebootPolicy,
                              phase: SupervisorPhase,
                              failingSince: Date?,
                              everHealthyThisSession: Bool,
                              history: RebootHistory,
                              now: Date,
                              systemBootedAt: Date? = nil) -> RebootDecision {
        guard policy.enabled else { return .wait }
        // Never reboot for a setup failure (a wrong binary path, a bad config).
        // Only a runner that was actually serving and then wedged past what a
        // process restart can fix is worth a reboot.
        guard everHealthyThisSession else { return .wait }
        guard phase == .failing, let failingSince else { return .wait }
        guard now.timeIntervalSince(failingSince) >= policy.escalateAfterSeconds else { return .wait }

        // Kernel boot-time backstop, independent of the on-disk history. If the
        // Mac itself booted more recently than the minimum interval, a reboot just
        // happened and did not clear the wedge, so do not loop. This holds even if
        // the persisted reboot history was lost across the reboot (an unflushed or
        // corrupt file), which a history-only guard would fail open on.
        if let systemBootedAt, now.timeIntervalSince(systemBootedAt) < policy.minIntervalSeconds {
            return .exhausted
        }

        let dayAgo = now.addingTimeInterval(-86_400)
        let recent = history.recoveryReboots.filter { $0 >= dayAgo }

        // Rebooted recently and still wedged: the reboot did not fix it, so do not
        // reboot again into a loop. Ask for a human instead.
        if let last = recent.max(), now.timeIntervalSince(last) < policy.minIntervalSeconds {
            return .exhausted
        }
        if recent.count >= policy.maxPerDay {
            return .exhausted
        }
        return .reboot
    }
}

/// The seam for the one privileged, irreversible action. The app implementation
/// runs the reboot; tests use a fake. Kept tiny on purpose.
public protocol SystemControlling: Sendable {
    /// Reboot the machine. Requires root (the headless LaunchDaemon).
    func reboot()
    /// When the machine last booted, used as a loop-guard backstop that does not
    /// depend on the persisted reboot history. nil if it cannot be read.
    func bootedAt() -> Date?
}
