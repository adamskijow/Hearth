// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

enum MonitorPresentation {
    static func title(_ snapshot: MonitorSnapshot) -> String {
        switch snapshot.phase {
        case .paused: return "Paused"
        case .healthy: return "Healthy"
        case .busy where snapshot.failure?.isInferenceLevel == true: return "Busy (verifying recovery)"
        case .busy: return "Busy (serving)"
        case .down where snapshot.failure?.isInferenceLevel == true: return "Inference wedged"
        case .down: return "Down"
        case .checking where snapshot.failure != nil: return "Confirming an issue"
        case .checking: return "Checking"
        }
    }

    static func symbol(_ snapshot: MonitorSnapshot) -> String {
        switch snapshot.phase {
        case .paused: return "pause.circle.fill"
        case .healthy: return "checkmark.circle.fill"
        case .busy: return "hourglass.circle.fill"
        case .down: return "exclamationmark.circle.fill"
        case .checking where snapshot.failure != nil: return "exclamationmark.triangle.fill"
        case .checking: return "circle.dotted"
        }
    }

    static func detail(_ snapshot: MonitorSnapshot) -> String {
        if snapshot.phase == .paused { return "Monitoring is paused for this runner." }
        if snapshot.phase == .busy, snapshot.failure?.isInferenceLevel == true {
            return "The runner is busy. Hearth Monitor is waiting to verify that real inference recovered."
        }
        if let failure = snapshot.failure { return failure.plainDescription }
        switch snapshot.phase {
        case .paused: return "Monitoring is paused for this runner."
        case .healthy:
            return snapshot.deepProbeConfigured && snapshot.deepProbeLastSucceeded == true
                ? "The API and configured inference check are answering."
                : "The runner API is answering."
        case .busy: return "The runner reports that it is busy serving work."
        case .checking: return "The first check is in progress."
        case .down: return "The runner is not serving."
        }
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "not checked yet" }
        let interval = now.timeIntervalSince(date)
        if interval >= 0 && interval < 2 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = interval >= 3600
            ? [.day, .hour, .minute]
            : [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, interval)) ?? "under a second"
    }
}

/// Concrete next steps for states that Monitor can diagnose but, by design,
/// cannot repair inside App Sandbox. Guidance stays beside the live evidence so
/// a failure is useful without implying process-control authority.
enum MonitorActionGuidance {
    static func runner(target: MonitorTarget, snapshot: MonitorSnapshot) -> String? {
        guard let failure = snapshot.failure else { return nil }
        let runner = target.runnerKind.displayName
        switch failure {
        case .unreachable:
            return "Start \(runner) and confirm its server is running at the configured address, then choose Check Now."
        case .timedOut:
            return "Check whether \(runner) or the Mac is overloaded. Let active work finish, then choose Check Now."
        case .http(let status):
            return httpGuidance(status: status, runner: runner, inference: false)
        case .transport:
            return "Verify the host, port, HTTPS certificate, and network connection, then test the runner again in Settings."
        case .inferenceTimedOut:
            return "Stop any stuck request or restart \(runner) with its own controls, confirm the probe model fits available memory, then choose Check Now."
        case .inferenceHTTP(let status):
            return httpGuidance(status: status, runner: runner, inference: true)
        case .inferenceTransport:
            return "Confirm the configured probe model exists and can generate directly in \(runner), then choose Check Now."
        }
    }

    static func appleModel(_ snapshot: AppleModelHealthSnapshot) -> String? {
        if snapshot.deferredReason != nil {
            return "Let the Mac return to a normal power, thermal, or service state, then run the functional check again."
        }
        switch snapshot.phase {
        case .verifying:
            return "Let current on-device model work finish, then run the functional check again. Hearth will wait for confirmation before alerting."
        case .down:
            return "Run the check again when the Mac is idle. If it repeatedly fails, restart the Mac; only macOS can restart the underlying model service."
        case .slow:
            return "Check again when the Mac is idle and off Low Power Mode. Compare the result with this Mac's recent baseline."
        case .unavailable:
            switch snapshot.availability {
            case .available:
                return "Run Check Availability again. If the state persists, restart Hearth Monitor."
            case .unavailable(.unsupportedOS):
                return "Update to macOS 26 or later, or use Local AI Runner monitoring on this Mac."
            case .unavailable(.deviceNotEligible):
                return "This model cannot run on this Mac. Local AI Runner monitoring remains available."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings, wait for preparation to finish, then check again."
            case .unavailable(.modelNotReady):
                return "Keep the Mac connected to power and the network while macOS prepares the model, then check again."
            case .unavailable(.unsupportedLocale):
                return "Choose a supported language and locale in System Settings, then check again."
            case .unavailable(.frameworkUnavailable):
                return "Install current macOS updates and restart Hearth Monitor. Restart the Mac if the framework remains unavailable."
            }
        case .checking, .available, .healthy:
            return nil
        }
    }

    static func incident(_ incident: MonitorIncident) -> String {
        if incident.targetID == AppleModelHealthSnapshot.incidentTargetID {
            return "Retry when the Mac is idle, and restart the Mac if the failure persists."
        }
        if incident.inferenceLevel {
            return "Stop stuck work or restart the runner, and verify that the probe model fits available memory."
        }
        return "Confirm that the runner is running and reachable at its configured address."
    }

    private static func httpGuidance(status: Int, runner: String, inference: Bool) -> String {
        switch status {
        case 401, 403:
            return "Update the runner's bearer credential in Settings, test the connection, then check again."
        case 404 where inference:
            return "Confirm the configured probe model exists in \(runner), then test the runner again in Settings."
        case 404:
            return "Confirm that the selected runner type and endpoint are correct, then test the connection in Settings."
        case 429:
            return "Let the runner's current work finish, then check again. Increase the check interval if this recurs."
        case 500...599:
            return "Review \(runner)'s logs and restart it with its own controls if the error persists, then choose Check Now."
        default:
            return "Review HTTP \(status) in \(runner), verify the configured endpoint, then choose Check Now."
        }
    }
}

enum AppleModelPresentation {
    static func title(_ snapshot: AppleModelHealthSnapshot) -> String {
        switch snapshot.phase {
        case .checking: return "Checking"
        case .available: return "Available"
        case .healthy: return "Healthy"
        case .slow: return "Responding slowly"
        case .verifying:
            return snapshot.failure == .timedOut
                ? "Verifying a possible stall" : "Verifying a functional issue"
        case .down:
            return snapshot.failure == .timedOut
                ? "Not responding" : "Functional check failing"
        case .unavailable:
            switch snapshot.availability {
            case .available: return "Unavailable"
            case .unavailable(.unsupportedOS): return "Requires macOS 26"
            case .unavailable(.deviceNotEligible): return "Mac not eligible"
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off"
            case .unavailable(.modelNotReady): return "Model not ready"
            case .unavailable(.unsupportedLocale): return "Locale not supported"
            case .unavailable(.frameworkUnavailable): return "Framework unavailable"
            }
        }
    }

    static func symbol(_ snapshot: AppleModelHealthSnapshot) -> String {
        switch snapshot.phase {
        case .healthy, .available: return "checkmark.circle.fill"
        case .slow: return "gauge.with.dots.needle.67percent"
        case .down: return "exclamationmark.circle.fill"
        case .verifying: return "exclamationmark.triangle.fill"
        case .unavailable: return "circle.slash"
        case .checking: return "circle.dotted"
        }
    }

    static func detail(_ snapshot: AppleModelHealthSnapshot) -> String {
        if let deferredReason = snapshot.deferredReason { return deferredReason }
        if let failure = snapshot.failure { return failure.plainDescription }
        switch snapshot.phase {
        case .checking: return "Reading the system model's public availability state."
        case .available: return "The system model is available. Functional checks are off."
        case .healthy:
            if let latency = snapshot.lastLatencySeconds {
                return String(format: "The private functional check completed in %.2f seconds.", latency)
            }
            return "The private functional check completed."
        case .slow:
            return "The model completed the check, but substantially slower than this Mac's recent baseline."
        case .verifying:
            return "One check did not finish. Hearth will not call this an incident until it can confirm the problem."
        case .down:
            return "Multiple functional checks failed. Hearth cannot restart Apple's system model service."
        case .unavailable:
            switch snapshot.availability {
            case .available: return "The model is temporarily unavailable."
            case .unavailable(.unsupportedOS):
                return "Apple Foundation Models requires macOS 26 or later. Local AI runner monitoring still works."
            case .unavailable(.deviceNotEligible):
                return "This Mac is not eligible for Apple Intelligence. Local AI runner monitoring still works."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings to enable functional monitoring."
            case .unavailable(.modelNotReady):
                return "macOS reports that the model is downloading or otherwise not ready yet."
            case .unavailable(.unsupportedLocale):
                return "Apple's system model does not support the Mac's current language or locale."
            case .unavailable(.frameworkUnavailable):
                return "The public Foundation Models framework could not report a usable state."
            }
        }
    }
}

enum MonitorDiagnosticsText {
    static func report(target: MonitorTarget,
                       snapshot: MonitorSnapshot?,
                       fullHearth: FullHearthBridgeSnapshot? = nil) -> String {
        var lines = [
            "Hearth Monitor diagnostics",
            "Generated: \(Date().formatted(.iso8601))",
            "Runner: \(target.name) (\(target.runnerKind.displayName))",
            "Endpoint: \(target.scheme)://\(target.host):\(target.port)",
            "Monitoring: \(target.isEnabled ? "enabled" : "paused")",
            "Runner authentication: \(target.authentication == .bearer ? "bearer credential in Keychain" : "none")",
        ]
        if let snapshot {
            lines.append("State: \(MonitorPresentation.title(snapshot))")
            lines.append("Detail: \(MonitorPresentation.detail(snapshot))")
            lines.append("Last checked: \(snapshot.checkedAt?.formatted(.iso8601) ?? "never")")
            lines.append("Consecutive failures: \(snapshot.consecutiveFailures)")
            lines.append("Deep probe configured: \(snapshot.deepProbeConfigured ? "yes" : "no")")
            if snapshot.deepProbeConfigured {
                let deepResult: String
                switch snapshot.deepProbeLastSucceeded {
                case .some(true): deepResult = "passed"
                case .some(false): deepResult = "failed"
                case .none: deepResult = "not completed"
                }
                lines.append("Deep probe result: \(deepResult)")
                lines.append("Deep probe at: \(snapshot.deepProbeLastAt?.formatted(.iso8601) ?? "never")")
                lines.append("Deep probe cadence: \(Int(target.clampedDeepProbeInterval)) seconds")
                if let reason = snapshot.deepProbeDeferredReason {
                    lines.append("Deep probe deferred: \(reason)")
                }
            }
            if snapshot.residentModels.isEmpty {
                lines.append("Resident models: none reported")
            } else {
                lines.append("Resident models: \(snapshot.residentModels.map(\.name).joined(separator: ", "))")
            }
            if let note = snapshot.modelsNote { lines.append("Model note: \(note)") }
        } else {
            lines.append("State: Not checked yet")
        }
        if let fullHearth {
            lines.append("Full Hearth connection: \(fullHearth.phase.rawValue)")
            lines.append("Full Hearth detail: \(fullHearth.message)")
            if let status = fullHearth.status {
                lines.append("Full Hearth phase: \(status.phase)")
                lines.append("Full Hearth mode: \(status.mode ?? "not reported")")
                lines.append("Full Hearth restarts: \(status.restartCount)")
                lines.append("Full Hearth credential: \(status.credentialAccess ?? "scope not reported")")
                lines.append("Full Hearth reboot escalation: \(status.rebootOnWedge == true ? "configured" : "not reported or off")")
            }
        } else {
            lines.append("Full Hearth connection: not configured")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
