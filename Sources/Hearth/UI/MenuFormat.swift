// SPDX-License-Identifier: MIT

import AppKit
import SupervisorCore

/// Presentation only: turns the typed `SupervisorState` and events into the
/// strings, symbols, and colors the menubar shows. No decisions here.
enum MenuFormat {
    static func symbolName(for phase: SupervisorPhase) -> String {
        switch phase {
        case .stopped: return "moon.zzz"
        case .starting: return "hourglass"
        case .healthy: return "flame.fill"
        case .down: return "clock.arrow.circlepath"        // not serving, waiting out the backoff
        case .restarting: return "arrow.triangle.2.circlepath" // actively cycling
        case .failing: return "exclamationmark.triangle.fill"
        }
    }

    static func tint(for phase: SupervisorPhase) -> NSColor? {
        switch phase {
        case .stopped: return .secondaryLabelColor
        case .starting: return .systemBlue
        case .healthy: return nil // template, adapts to the menubar
        case .down, .restarting: return .systemOrange
        case .failing: return .systemRed
        }
    }

    /// The prominent one-line health statement (shown bold and colored). No
    /// "Status:" label: the line is the status.
    static func headline(_ state: SupervisorState, now: Date) -> String {
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

    /// The dim detail line under the headline: what is being supervised and for
    /// how long. Folds in the runner and mode (which were a separate static row)
    /// alongside uptime and restart count, so the line actually changes.
    static func contextLine(_ state: SupervisorState, runnerName: String, managed: Bool, now: Date) -> String {
        var parts = ["\(runnerName), \(managed ? "managed" : "attached")"]
        if let uptime = state.uptime(asOf: now) {
            parts.append("Up \(duration(uptime))")
        }
        if state.restartCount > 0 {
            parts.append("\(state.restartCount) restart\(state.restartCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func retrySuffix(_ state: SupervisorState, now: Date) -> String {
        guard let next = state.nextRetryAt else { return "" }
        let seconds = max(0, next.timeIntervalSince(now))
        return " (retry in \(Int(seconds.rounded()))s)"
    }

    static func model(_ model: ResidentModel) -> String {
        if let size = model.sizeBytes {
            return "\(model.name) (\(byteString(size)))"
        }
        return model.name
    }

    static func byteString(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: count)
    }

    static func duration(_ interval: TimeInterval) -> String {
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

    static func describe(_ event: SupervisorEvent) -> String {
        switch event {
        case .started: return "Started"
        case .becameHealthy: return "Became healthy"
        case .down(let reason): return "Down: \(reason.label)"
        case .restartScheduled(let attempt, let backoff):
            return "Restart scheduled (attempt \(attempt), in \(Int(backoff))s)"
        case .restarted(let attempt): return "Restarted (attempt \(attempt))"
        case .recovered: return "Recovered"
        case .enteredFailing(let count, let window):
            return "Failing: \(count) failures within \(Int(window))s"
        case .modelsUpdated(let models):
            return "Models: \(models.map(\.name).joined(separator: ", "))"
        case .stopped: return "Stopped"
        }
    }
}
