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
            return state.busy ? "Healthy (busy)" : "Healthy"
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
    /// uptime and restart count, so the line actually changes. The mode is said in
    /// plain words rather than managed/attached, matching the Preferences toggle.
    public static func contextLine(_ state: SupervisorState, runnerName: String, managed: Bool, now: Date) -> String {
        var parts = ["\(runnerName), \((managed ? ModeKind.managed : .attached).statusPhrase)"]
        if let uptime = state.uptime(asOf: now) {
            parts.append("Up \(duration(uptime))")
        }
        if state.restartCount > 0 {
            parts.append("\(state.restartCount) restart\(state.restartCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Next-step guidance for the two states that do not resolve on their own.
    /// Lives here rather than in the menu builder so the wording is locked by
    /// tests, like every other user-facing warning.
    public static let crashLoopGuidance = [
        "The runner keeps failing right after starting; Hearth is still retrying, more slowly.",
        "Open Logs below shows why it is failing; `hearth doctor` in Terminal checks the setup."
    ]

    /// Shown when a watched (attached-mode) runner is down: in that mode nothing
    /// restarts it, and the user needs to know that plainly.
    public static func watchingOnlyNotice(runnerName: String) -> String {
        "Hearth is watching only; it will not start \(runnerName) itself in this mode."
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
        case .warmupFinished(let missing):
            return missing.isEmpty
                ? "Warmed the models back up after the restart"
                : "Models not restored after the restart: \(missing.joined(separator: ", "))"
        case .warmupSkippedAfterCrash(let models):
            return "Skipped reloading \(models.joined(separator: ", ")): the runner had just crashed loading them"
        case .memoryLimitExceeded(let resident, let limit):
            return "Memory limit restart (\(byteString(resident)) resident, limit \(byteString(limit)))"
        case .stopped: return "Stopped"
        }
    }
}
