// SPDX-License-Identifier: MIT

import Foundation

/// The sleep preventing power assertion, behind a protocol. The engine decides
/// *when* to hold it (while supervising) and *when* to release it (on stop); the
/// app provides the IOKit backed implementation, and tests provide a recorder.
///
/// Both calls must be idempotent: holding while already held, or releasing while
/// already released, does nothing.
public protocol PowerManaging: Sendable {
    func hold()
    func release()
}

/// A power manager that does nothing. Useful as a default and in contexts where
/// keeping the machine awake is not wanted.
public struct NoopPowerManager: PowerManaging {
    public init() {}
    public func hold() {}
    public func release() {}
}
