// SPDX-License-Identifier: MIT

import AppKit
import Combine
import HearthMonitorCore
import SwiftUI

@MainActor
final class AppleModelDetailsModel: ObservableObject {
    @Published var snapshot: AppleModelHealthSnapshot
    @Published var settings: AppleModelMonitorSettings

    init(snapshot: AppleModelHealthSnapshot, settings: AppleModelMonitorSettings) {
        self.snapshot = snapshot
        self.settings = settings
    }
}

@MainActor
final class AppleModelDetailsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppleModelDetailsModel
    private let onCheck: () -> Void
    private let onOpenLab: () -> Void
    private let onOpenSettings: () -> Void

    init(snapshot: AppleModelHealthSnapshot,
         settings: AppleModelMonitorSettings,
         onCheck: @escaping () -> Void,
         onOpenLab: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        model = AppleModelDetailsModel(snapshot: snapshot, settings: settings)
        self.onCheck = onCheck
        self.onOpenLab = onOpenLab
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func show(snapshot: AppleModelHealthSnapshot, settings: AppleModelMonitorSettings) {
        model.snapshot = snapshot
        model.settings = settings
        if window == nil {
            let view = AppleModelDetailsView(
                model: model,
                onCopy: { [weak self] in self?.copyReport() },
                onCheck: onCheck,
                onOpenLab: onOpenLab,
                onOpenSettings: onOpenSettings,
                onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Apple Intelligence Health"
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 560, height: 480)
            window.setContentSize(NSSize(width: 640, height: 700))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ snapshot: AppleModelHealthSnapshot) {
        model.snapshot = snapshot
    }

    func windowWillClose(_ notification: Notification) {
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    private func copyReport() {
        let report = AppleModelDiagnosticsText.report(
            snapshot: model.snapshot,
            settings: model.settings)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

struct AppleModelDetailsView: View {
    @ObservedObject var model: AppleModelDetailsModel
    let onCopy: () -> Void
    let onCheck: () -> Void
    let onOpenLab: () -> Void
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusCard
                    timingCard
                    privacyCard
                    recoveryCard
                }
                .padding(22)
            }
            Divider()
            HStack {
                Button("Copy Diagnostics", systemImage: "doc.on.doc", action: onCopy)
                Button("Monitoring Settings…", action: onOpenSettings)
                Button("Model Lab…", action: onOpenLab)
                Spacer()
                Button(model.settings.functionalChecksEnabled
                       ? "Run Functional Check" : "Check Availability",
                       action: onCheck)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: AppleModelPresentation.symbol(model.snapshot))
                .font(.system(size: 32))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Intelligence").font(.title2.weight(.semibold))
                Text(AppleModelPresentation.title(model.snapshot))
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Text(AppleModelPresentation.detail(model.snapshot))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        GroupBox("Monitoring") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                row("Availability", availabilityText)
                row("Last availability check", MonitorPresentation.relative(model.snapshot.checkedAt))
                row("Functional checks", model.settings.functionalChecksEnabled ? "On" : "Off")
                row("Check interval", MonitorPresentation.duration(model.settings.clampedCheckInterval))
                row("Confirmation", "\(model.settings.clampedFailureThreshold) failed checks")
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timingCard: some View {
        GroupBox("Functional response") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                row("Last successful response", MonitorPresentation.relative(model.snapshot.functionalSucceededAt))
                row("Last attempt", MonitorPresentation.relative(model.snapshot.functionalCheckedAt))
                row("Last response time", formatted(model.snapshot.lastLatencySeconds))
                row("Recent baseline", formatted(model.snapshot.baselineLatencySeconds))
                row("Local samples", "\(model.snapshot.latencySamples.count) of 12")
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var privacyCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Private by design").fontWeight(.medium)
                Text("The fixed canary prompt runs through Apple's on-device Foundation Models framework. Hearth stores only timing, status, and incident metadata; it does not store generated text or send it to the developer.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield")
        }
        .padding(12)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var recoveryCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery boundary").fontWeight(.medium)
                Text("Hearth uses a fresh app session after a completed or failed check and never stacks requests behind a timed-out one. macOS owns the underlying model service, so this App Store edition cannot restart it or claim an OS-level recovery.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "wrench.and.screwdriver")
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var availabilityText: String {
        switch model.snapshot.availability {
        case .available: return "Available"
        case .unavailable(.unsupportedOS): return "Requires macOS 26"
        case .unavailable(.deviceNotEligible): return "This Mac is not eligible"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off"
        case .unavailable(.modelNotReady): return "Model is not ready"
        case .unavailable(.unsupportedLocale): return "Current locale is not supported"
        case .unavailable(.frameworkUnavailable): return "Framework is unavailable"
        }
    }

    private func formatted(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "Not measured yet" }
        return String(format: "%.2f seconds", seconds)
    }

    private var statusColor: Color {
        switch model.snapshot.phase {
        case .healthy, .available: return .green
        case .slow, .verifying: return .orange
        case .down: return .red
        case .checking, .unavailable: return .secondary
        }
    }
}

enum AppleModelDiagnosticsText {
    static func report(snapshot: AppleModelHealthSnapshot,
                       settings: AppleModelMonitorSettings) -> String {
        var lines = [
            "Hearth Monitor Apple Intelligence diagnostics",
            "Generated: \(Date().formatted(.iso8601))",
            "State: \(AppleModelPresentation.title(snapshot))",
            "Detail: \(AppleModelPresentation.detail(snapshot))",
            "Availability: \(availability(snapshot.availability))",
            "Last availability check: \(snapshot.checkedAt?.formatted(.iso8601) ?? "never")",
            "Functional checks: \(settings.functionalChecksEnabled ? "enabled" : "disabled")",
            "Functional interval seconds: \(Int(settings.clampedCheckInterval))",
            "Last functional check: \(snapshot.functionalCheckedAt?.formatted(.iso8601) ?? "never")",
            "Last successful response: \(snapshot.functionalSucceededAt?.formatted(.iso8601) ?? "never")",
            "Last latency seconds: \(number(snapshot.lastLatencySeconds))",
            "Baseline latency seconds: \(number(snapshot.baselineLatencySeconds))",
            "Consecutive failures: \(snapshot.consecutiveFailures)",
            "Stored latency sample count: \(snapshot.latencySamples.count)",
            "Generated content retained: no",
            "System model restart capability: unavailable to App Sandbox",
        ]
        if let deferred = snapshot.deferredReason { lines.append("Deferral: \(deferred)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func availability(_ value: AppleModelAvailability) -> String {
        switch value {
        case .available: return "available"
        case .unavailable(let reason): return reason.rawValue
        }
    }

    private static func number(_ value: TimeInterval?) -> String {
        guard let value else { return "not measured" }
        return String(format: "%.3f", value)
    }
}
