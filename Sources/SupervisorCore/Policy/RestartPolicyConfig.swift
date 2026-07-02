// SPDX-License-Identifier: MIT

import Foundation

/// A daily wall-clock window ("HH:MM-HH:MM") during which scheduled maintenance
/// restarts may fire, so a routine cycle never lands mid-afternoon while people
/// are using the runner. Spans midnight when the end is before the start
/// (23:00-06:00). Pure and testable; the engine supplies the current minute.
public struct MaintenanceWindow: Sendable, Equatable {
    public let startMinute: Int
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// Parse "HH:MM-HH:MM" (24-hour). Nil for anything else, including a window
    /// whose start equals its end, which would never fire.
    public static func parse(_ raw: String) -> MaintenanceWindow? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 2,
              let start = minuteOfDay(String(parts[0])),
              let end = minuteOfDay(String(parts[1])),
              start != end else { return nil }
        return MaintenanceWindow(startMinute: start, endMinute: end)
    }

    private static func minuteOfDay(_ raw: String) -> Int? {
        let pieces = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]), (0...23).contains(hour),
              let minute = Int(pieces[1]), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    public func contains(minuteOfDay minute: Int) -> Bool {
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        // Spans midnight: inside when after the start or before the end.
        return minute >= startMinute || minute < endMinute
    }
}

/// Every timing knob the decision logic needs, in one data driven place. No
/// magic numbers live in the machine or the engine; they all come from here, and
/// here is populated from the on disk config.
public struct RestartPolicyConfig: Sendable, Equatable {
    /// How often to probe health while healthy.
    public var probeInterval: TimeInterval
    /// How long a readiness HTTP request may take before it counts as timed out
    /// (wedged).
    public var probeTimeout: TimeInterval
    /// How long after a spawn to keep treating "alive but not ready" as normal
    /// warm up rather than a failure.
    public var startupGrace: TimeInterval
    /// How often to probe while starting or restarting, before readiness.
    public var startupProbeInterval: TimeInterval
    /// The first backoff, before any multiplier is applied.
    public var initialBackoff: TimeInterval
    /// Each consecutive failure multiplies the backoff by this.
    public var backoffMultiplier: Double
    /// The backoff is never longer than this.
    public var maxBackoff: TimeInterval
    /// This many failures inside `crashLoopWindow` trips the failing phase.
    public var crashLoopThreshold: Int
    /// The sliding window over which failures are counted for crash loop
    /// detection.
    public var crashLoopWindow: TimeInterval
    /// The slow retry cadence used while failing, instead of fast backoff.
    public var failingProbeInterval: TimeInterval
    /// Cycle a long-healthy runner this often to clear the memory creep and VRAM
    /// fragmentation that degrade a 24/7 runner. Zero disables it.
    public var maintenanceRestartInterval: TimeInterval
    /// Restart the runner when its binary changes on disk (an upgrade), so a
    /// supervised runner adopts the new version instead of serving the old one
    /// forever. Off by default.
    public var restartOnBinaryChange: Bool
    /// When set, scheduled maintenance restarts fire only inside this daily
    /// wall-clock window; a due restart waits for the window to open.
    public var maintenanceWindow: MaintenanceWindow?

    public init(probeInterval: TimeInterval = 5,
                probeTimeout: TimeInterval = 2,
                startupGrace: TimeInterval = 30,
                startupProbeInterval: TimeInterval = 1,
                initialBackoff: TimeInterval = 1,
                backoffMultiplier: Double = 2,
                maxBackoff: TimeInterval = 60,
                crashLoopThreshold: Int = 5,
                crashLoopWindow: TimeInterval = 60,
                failingProbeInterval: TimeInterval = 30,
                maintenanceRestartInterval: TimeInterval = 0,
                restartOnBinaryChange: Bool = false,
                maintenanceWindow: MaintenanceWindow? = nil) {
        self.probeInterval = probeInterval
        self.probeTimeout = probeTimeout
        self.startupGrace = startupGrace
        self.startupProbeInterval = startupProbeInterval
        self.initialBackoff = initialBackoff
        self.backoffMultiplier = backoffMultiplier
        self.maxBackoff = maxBackoff
        self.crashLoopThreshold = crashLoopThreshold
        self.crashLoopWindow = crashLoopWindow
        self.failingProbeInterval = failingProbeInterval
        self.maintenanceRestartInterval = maintenanceRestartInterval
        self.restartOnBinaryChange = restartOnBinaryChange
        self.maintenanceWindow = maintenanceWindow
    }

    /// Whether a periodic maintenance restart is due for a runner healthy since
    /// `healthySince`, as of `now`. Disabled when the interval is not positive.
    /// With a maintenance window configured, a due restart waits until the
    /// current wall-clock minute (supplied by the caller) is inside the window.
    public func maintenanceRestartDue(healthySince: Date?, now: Date, minuteOfDay: Int? = nil) -> Bool {
        guard maintenanceRestartInterval > 0, let healthySince else { return false }
        guard now.timeIntervalSince(healthySince) >= maintenanceRestartInterval else { return false }
        if let window = maintenanceWindow, let minuteOfDay {
            return window.contains(minuteOfDay: minuteOfDay)
        }
        return true
    }

    /// The backoff for the nth consecutive failure (n starting at 1), capped.
    public func backoff(forConsecutiveFailure n: Int) -> TimeInterval {
        guard n >= 1 else { return initialBackoff }
        let raw = initialBackoff * pow(backoffMultiplier, Double(n - 1))
        return min(raw, maxBackoff)
    }
}
