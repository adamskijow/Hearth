// SPDX-License-Identifier: MIT

import Foundation

/// Thresholds for the pressure alerts. High memory pressure is the precursor to
/// macOS's process killer terminating the runner (usually the biggest memory
/// user); sustained high thermals throttle performance on a closet Mac. Hearth
/// already samples both, so this just turns that data into a heads-up.
public struct PressureThresholds: Sendable, Equatable {
    /// Alert when system memory used reaches this percent. Zero disables it.
    public var memoryAlertPercent: Int
    /// Alert when the thermal state is serious or critical.
    public var thermalAlerts: Bool

    public init(memoryAlertPercent: Int = 90, thermalAlerts: Bool = true) {
        self.memoryAlertPercent = memoryAlertPercent
        self.thermalAlerts = thermalAlerts
    }

    /// Hysteresis: clear the memory alert only once it drops a margin below the
    /// alert level, so it does not flap around the threshold.
    var memoryClearPercent: Int { max(0, memoryAlertPercent - 10) }
}

public enum PressureSignal: Sendable, Equatable {
    case memoryHigh(percent: Int)
    case memoryEased(percent: Int)
    case thermalElevated(String)
    case thermalEased(String)
}

/// What the monitor remembers between samples, so it alerts on a crossing rather
/// than on every sample, and pairs each alert with an all-clear.
public struct PressureMonitorState: Sendable, Equatable {
    public var memoryAlerted: Bool
    public var thermalAlerted: Bool
    public init(memoryAlerted: Bool = false, thermalAlerted: Bool = false) {
        self.memoryAlerted = memoryAlerted
        self.thermalAlerted = thermalAlerted
    }
}

/// Pure: turn a metrics sample plus the previous state into the alerts to send.
public enum PressureEvaluator {
    public static func evaluate(_ metrics: SystemMetrics,
                                thresholds: PressureThresholds,
                                state: inout PressureMonitorState) -> [PressureSignal] {
        var signals: [PressureSignal] = []

        if thresholds.memoryAlertPercent > 0, let fraction = metrics.memoryUsedFraction {
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            if !state.memoryAlerted, percent >= thresholds.memoryAlertPercent {
                state.memoryAlerted = true
                signals.append(.memoryHigh(percent: percent))
            } else if state.memoryAlerted, percent <= thresholds.memoryClearPercent {
                state.memoryAlerted = false
                signals.append(.memoryEased(percent: percent))
            }
        }

        if thresholds.thermalAlerts {
            if !state.thermalAlerted, metrics.thermal.isElevated {
                state.thermalAlerted = true
                signals.append(.thermalElevated(metrics.thermal.label))
            } else if state.thermalAlerted, !metrics.thermal.isElevated {
                state.thermalAlerted = false
                signals.append(.thermalEased(metrics.thermal.label))
            }
        }

        return signals
    }
}
