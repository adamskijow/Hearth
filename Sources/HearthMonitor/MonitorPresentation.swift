// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

enum MonitorPresentation {
    static func title(_ snapshot: MonitorSnapshot) -> String {
        switch snapshot.phase {
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
        case .healthy: return "checkmark.circle.fill"
        case .busy: return "hourglass.circle.fill"
        case .down: return "exclamationmark.circle.fill"
        case .checking where snapshot.failure != nil: return "exclamationmark.triangle.fill"
        case .checking: return "circle.dotted"
        }
    }

    static func detail(_ snapshot: MonitorSnapshot) -> String {
        if snapshot.phase == .busy, snapshot.failure?.isInferenceLevel == true {
            return "The runner is busy. Hearth Monitor is waiting to verify that real inference recovered."
        }
        if let failure = snapshot.failure { return failure.plainDescription }
        switch snapshot.phase {
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
