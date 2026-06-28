// SPDX-License-Identifier: MIT

import Foundation

/// A coarse thermal reading from the public thermal state API. This is honest
/// observability (is the Mac about to throttle), not inference. It needs no root,
/// unlike powermetrics.
public enum ThermalState: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    public var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        case .unknown: return "unknown"
        }
    }

    /// Worth drawing attention to (the machine is heating up enough to throttle).
    public var isElevated: Bool {
        self == .serious || self == .critical
    }
}

/// A point in time snapshot of system conditions relevant to keeping a runner
/// healthy: heat (throttling risk) and memory (out of memory risk), plus the
/// runner child's resident footprint when known.
public struct SystemMetrics: Sendable, Equatable {
    public var thermal: ThermalState
    /// Fraction of physical memory in use, 0 to 1, when measurable.
    public var memoryUsedFraction: Double?
    /// Resident size of the runner child in bytes, when measurable.
    public var runnerResidentBytes: Int64?

    public init(thermal: ThermalState = .unknown,
                memoryUsedFraction: Double? = nil,
                runnerResidentBytes: Int64? = nil) {
        self.thermal = thermal
        self.memoryUsedFraction = memoryUsedFraction
        self.runnerResidentBytes = runnerResidentBytes
    }
}

/// Metrics sampling behind a protocol, so the app provides the real readers and
/// tests can stub it.
public protocol MetricsProviding: Sendable {
    func sample() -> SystemMetrics
}

/// Pure formatting for metrics, shared by the menubar and kept testable.
public enum MetricsFormat {
    public static func memoryPercent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// One line summary for the menubar, or nil if nothing is measurable.
    public static func summary(_ metrics: SystemMetrics) -> String? {
        var parts: [String] = []
        if metrics.thermal != .unknown {
            parts.append("thermal \(metrics.thermal.label)")
        }
        if let fraction = metrics.memoryUsedFraction {
            parts.append("memory \(memoryPercent(fraction))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
