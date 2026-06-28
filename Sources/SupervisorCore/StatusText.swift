// SPDX-License-Identifier: MIT

import Foundation

/// Pure, testable formatting of the supervisor's state and events into the
/// strings the UI shows. No AppKit here: the colors and SF Symbol names stay in
/// the app's MenuFormat. This lives in core so the user-facing wording is locked
/// down by tests rather than only eyeballed in the menu.
public enum StatusText {
    /// The prominent one-line health statement. No "Status:" label: the line is
    /// the status.
    public static func headline(_ state: SupervisorState, now: Date) -> String {
        switch state.phase {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting\u{2026}"
        case .healthy:
            return "Healthy"
        case .down:
            return "Down\(retrySuffix(state, now: now))"
        case .restarting:
            return "Restarting (attempt \(state.restartCount))"
        case .failing:
            return "Crash loop\(retrySuffix(state, now: now))"
        }
    }

    private static func retrySuffix(_ state: SupervisorState, now: Date) -> String {
        guard let next = state.nextRetryAt else { return "" }
        let seconds = max(0, next.timeIntervalSince(now))
        return " (retry in \(Int(seconds.rounded()))s)"
    }

    /// The detail line under the headline: what is being supervised and for how
    /// long. Folds in the runner and mode (a separate static row before) alongside
    /// uptime and restart count, so the line actually changes.
    public static func contextLine(_ state: SupervisorState, runnerName: String, managed: Bool, now: Date) -> String {
        var parts = ["\(runnerName), \(managed ? "managed" : "attached")"]
        if let uptime = state.uptime(asOf: now) {
            parts.append("Up \(duration(uptime))")
        }
        if state.restartCount > 0 {
            parts.append("\(state.restartCount) restart\(state.restartCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    public static func model(_ model: ResidentModel) -> String {
        if let size = model.sizeBytes {
            return "\(model.name) (\(byteString(size)))"
        }
        return model.name
    }

    public static func byteString(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: count)
    }

    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    public static func describe(_ event: SupervisorEvent) -> String {
        switch event {
        case .started: return "Started"
        case .becameHealthy: return "Became healthy"
        case .down(let reason): return "Down: \(reason.label)"
        case .restartScheduled(let attempt, let backoff):
            return "Restart scheduled (attempt \(attempt), in \(Int(backoff))s)"
        case .restarted(let attempt): return "Restarted (attempt \(attempt))"
        case .maintenanceRestart: return "Maintenance restart"
        case .recovered: return "Recovered"
        case .enteredFailing(let count, let window):
            return "Failing: \(count) failures within \(Int(window))s"
        case .modelsUpdated(let models):
            return "Models: \(models.map(\.name).joined(separator: ", "))"
        case .stopped: return "Stopped"
        }
    }
}
