// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Periodically samples system metrics and notifies on a memory or thermal
/// pressure crossing (and the all-clear), using the pure PressureEvaluator. It
/// gives a heads-up before macOS kills the runner under memory pressure, or
/// before sustained thermals throttle it, turning data Hearth already collects
/// into an alert.
final class PressureMonitor: @unchecked Sendable {
    private let metrics: MetricsProviding
    private let thresholds: PressureThresholds
    private let interval: TimeInterval
    private let notify: @Sendable (HearthNotification) -> Void
    private let lock = NSLock()
    private var state = PressureMonitorState()
    private var timer: DispatchSourceTimer?

    init(metrics: MetricsProviding,
         thresholds: PressureThresholds,
         interval: TimeInterval = 30,
         notify: @escaping @Sendable (HearthNotification) -> Void) {
        self.metrics = metrics
        self.thresholds = thresholds
        self.interval = interval
        self.notify = notify
    }

    func start() {
        guard thresholds.memoryAlertPercent > 0 || thresholds.thermalAlerts else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let signals = lock.withLock {
            PressureEvaluator.evaluate(metrics.sample(), thresholds: thresholds, state: &state)
        }
        for signal in signals {
            notify(Self.notification(for: signal))
        }
    }

    static func notification(for signal: PressureSignal) -> HearthNotification {
        switch signal {
        case .memoryHigh(let percent):
            return HearthNotification(level: .warning, title: "Hearth: memory pressure high",
                body: "System memory is at \(percent)%. Under pressure macOS may kill the runner, its biggest memory user.")
        case .memoryEased(let percent):
            return HearthNotification(level: .info, title: "Hearth: memory pressure eased",
                body: "System memory is back down to \(percent)%.")
        case .thermalElevated(let label):
            return HearthNotification(level: .warning, title: "Hearth: running hot (\(label))",
                body: "The Mac's thermal state is \(label); the runner may throttle.")
        case .thermalEased(let label):
            return HearthNotification(level: .info, title: "Hearth: temperatures eased",
                body: "The Mac's thermal state is back to \(label).")
        }
    }
}
