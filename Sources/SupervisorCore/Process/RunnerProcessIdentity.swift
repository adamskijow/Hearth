// SPDX-License-Identifier: MIT

import Foundation

/// Enough to recognize a specific runner process instance across a Hearth
/// restart. The start time is what makes it safe: a PID can be reused, but a PID
/// plus its start time uniquely identifies one process instance, so Hearth never
/// kills an unrelated process that happened to inherit a recycled PID.
public struct RunnerProcessIdentity: Codable, Sendable, Equatable {
    public var pid: Int32
    public var pgid: Int32
    public var startTimeSeconds: UInt64
    public var executablePath: String?

    public init(pid: Int32, pgid: Int32, startTimeSeconds: UInt64, executablePath: String? = nil) {
        self.pid = pid
        self.pgid = pgid
        self.startTimeSeconds = startTimeSeconds
        self.executablePath = executablePath
    }
}

/// The pure decision behind hard-crash orphan recovery. If Hearth is killed
/// without running its teardown (a hard SIGKILL, or a panic), the runner group it
/// spawned survives, re-parented to launchd, leaking GPU and unified memory. On
/// the next launch Hearth reads the recorded identity and decides whether the
/// process is still the same orphaned runner and should be swept.
public enum RunnerSweep {
    /// Sweep only when the recorded process is still alive AND is the same
    /// instance (same PID and start time). A dead PID, or a PID reused by a
    /// different process (a different start time), is never swept.
    public static func shouldSweep(recorded: RunnerProcessIdentity, live: RunnerProcessIdentity?) -> Bool {
        guard let live else { return false }
        return live.pid == recorded.pid && live.startTimeSeconds == recorded.startTimeSeconds
    }
}
