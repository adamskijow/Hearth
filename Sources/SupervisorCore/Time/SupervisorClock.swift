// SPDX-License-Identifier: MIT

import Foundation

/// Time, behind a protocol, so the supervisor never reaches for the wall clock
/// directly. Tests inject a clock they control; nothing in the decision logic
/// ever calls `Date()` or `Task.sleep` on its own.
public protocol SupervisorClock: Sendable {
    /// The current instant.
    var now: Date { get }

    /// Suspend for the given number of seconds. A non positive value returns
    /// immediately. Implementations must be cancellation aware.
    func sleep(seconds: TimeInterval) async throws
}

/// The real clock used by the deployed app.
public struct SystemClock: SupervisorClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
