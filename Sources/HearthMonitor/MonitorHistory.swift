// SPDX-License-Identifier: MIT

import AppKit
import Combine
import HearthMonitorCore
import SwiftUI

@MainActor
final class MonitorHistoryModel: ObservableObject {
    @Published var ledger: MonitorIncidentLedger
    @Published var problem: String?

    init(ledger: MonitorIncidentLedger, problem: String?) {
        self.ledger = ledger
        self.problem = problem
    }
}

@MainActor
final class MonitorHistoryController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model: MonitorHistoryModel
    private let onClearResolved: () -> Void
    private let onReset: () -> Void

    init(ledger: MonitorIncidentLedger,
         problem: String?,
         onClearResolved: @escaping () -> Void,
         onReset: @escaping () -> Void) {
        model = MonitorHistoryModel(ledger: ledger, problem: problem)
        self.onClearResolved = onClearResolved
        self.onReset = onReset
        super.init()
    }

    func show() {
        if window == nil {
            let view = MonitorHistoryView(
                model: model,
                onCopy: { [weak self] in self?.copyReport() },
                onClearResolved: onClearResolved,
                onReset: onReset,
                onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Hearth Monitor History"
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 560, height: 420)
            window.setContentSize(NSSize(width: 680, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(ledger: MonitorIncidentLedger, problem: String?) {
        model.ledger = ledger
        model.problem = problem
    }

    func windowWillClose(_ notification: Notification) {
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    private func copyReport() {
        let report = MonitorHistoryText.report(model.ledger)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

struct MonitorHistoryView: View {
    @ObservedObject var model: MonitorHistoryModel
    let onCopy: () -> Void
    let onClearResolved: () -> Void
    let onReset: () -> Void
    let onDone: () -> Void
    @State private var confirmingClear = false
    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Incident history").font(.title2.weight(.semibold))
                    Text("Confirmed outages only. A single transient missed check is never recorded as an incident.")
                        .foregroundStyle(.secondary)
                }
                if let problem = model.problem {
                    HStack(alignment: .top) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reset History…") { confirmingReset = true }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if model.ledger.incidents.isEmpty {
                    ContentUnavailableView(
                        "No incidents",
                        systemImage: "checkmark.shield",
                        description: Text("Confirmed runner outages will appear here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.ledger.incidents) { incident in
                        IncidentRow(incident: incident)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(20)
            Divider()
            HStack {
                Button("Copy Report", systemImage: "doc.on.doc", action: onCopy)
                    .disabled(model.ledger.incidents.isEmpty)
                Button("Clear Resolved…", role: .destructive) { confirmingClear = true }
                    .disabled(!model.ledger.incidents.contains(where: { $0.endedAt != nil }))
                Spacer()
                Text("Up to \(model.ledger.limit) incidents are kept locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
        }
        .alert("Clear resolved incidents?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Resolved", role: .destructive, action: onClearResolved)
        } message: {
            Text("Active outages stay in history until they recover or monitoring stops.")
        }
        .alert("Reset unreadable history?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset History", role: .destructive, action: onReset)
        } message: {
            Text("This replaces the unreadable history file with an empty one. Runner settings are not affected.")
        }
    }
}

private struct IncidentRow: View {
    let incident: MonitorIncident

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: incident.endedAt == nil
                  ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(incident.endedAt == nil ? Color.red : Color.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(incident.targetName).fontWeight(.semibold)
                    if incident.inferenceLevel {
                        Text("INFERENCE")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(statusText).font(.callout).foregroundStyle(statusColor)
                }
                Text(incident.cause)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(timingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch incident.resolution {
        case nil: return "Active"
        case .recovered: return "Recovered"
        case .monitoringStopped: return "Monitoring stopped"
        }
    }

    private var statusColor: Color { incident.endedAt == nil ? .red : .secondary }

    private var timingText: String {
        let started = incident.startedAt.formatted(date: .abbreviated, time: .shortened)
        if incident.endedAt == nil {
            return "Started \(started) · active for \(durationText(Date().timeIntervalSince(incident.startedAt)))"
        }
        return "Started \(started) · lasted \(durationText(incident.duration))"
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = duration >= 3600 ? [.day, .hour, .minute] : [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: duration) ?? "under a second"
    }
}

enum MonitorHistoryText {
    static func report(_ ledger: MonitorIncidentLedger) -> String {
        guard !ledger.incidents.isEmpty else { return "Hearth Monitor incident history\nNo incidents.\n" }
        let lines = ledger.incidents.map { incident in
            let end = incident.endedAt?.formatted(.iso8601) ?? "active"
            let resolution = incident.resolution?.rawValue ?? "active"
            let level = incident.inferenceLevel ? "inference" : "api"
            return "\(incident.startedAt.formatted(.iso8601)) | \(end) | \(resolution) | \(level) | \(incident.targetName) | \(incident.cause)"
        }
        return (["Hearth Monitor incident history"] + lines).joined(separator: "\n") + "\n"
    }
}
