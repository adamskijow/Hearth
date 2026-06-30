// SPDX-License-Identifier: MIT

import Foundation

/// The optional deep readiness probe. When set, the engine periodically runs a tiny
/// inference against `model` (a one-token generation) on top of the cheap shallow
/// probe, so it catches a wedged model runner that still answers the shallow
/// endpoint. Off by default (nil) because it must name a model and does GPU work;
/// the shallow `/api/version` probe stays the default. The probe sends no
/// `keep_alive`, so model residency follows the runner's own policy, not the probe's.
public struct DeepProbeConfig: Sendable, Equatable {
    public var model: String
    /// How often to run the deep probe (separate from, and slower than, the shallow
    /// probe interval, because it is expensive).
    public var interval: TimeInterval
    /// How long the deep probe may take before it counts as wedged. Generous,
    /// because a cold model load is legitimately slow.
    public var timeout: TimeInterval

    public init(model: String, interval: TimeInterval, timeout: TimeInterval) {
        self.model = model
        self.interval = interval
        self.timeout = timeout
    }
}
