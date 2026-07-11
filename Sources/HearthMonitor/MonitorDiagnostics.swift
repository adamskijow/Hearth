// SPDX-License-Identifier: MIT

import AppKit
import Combine
import HearthMonitorCore
import SwiftUI

@MainActor
final class MonitorDiagnosticsModel: ObservableObject {
    @Published var selectedID: UUID?
    init(selectedID: UUID?) { self.selectedID = selectedID }
}

@MainActor
final class MonitorDiagnosticsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = MonitorDiagnosticsModel(selectedID: nil)
    private let fleet: MonitorFleetCoordinator
    private let fullHearthBridge: FullHearthBridgeCoordinator
    private let onConnectFullHearth: (UUID) -> Void
    private let onOpenSettings: () -> Void

    init(fleet: MonitorFleetCoordinator,
         fullHearthBridge: FullHearthBridgeCoordinator,
         onConnectFullHearth: @escaping (UUID) -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.fleet = fleet
        self.fullHearthBridge = fullHearthBridge
        self.onConnectFullHearth = onConnectFullHearth
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func show(selectedID: UUID?) {
        if let selectedID { model.selectedID = selectedID }
        if model.selectedID == nil { model.selectedID = fleet.targets.first?.id }
        if window == nil {
            let view = MonitorDiagnosticsView(
                model: model,
                fleet: fleet,
                fullHearthBridge: fullHearthBridge,
                onCheck: { [weak self] id in
                    Task { await self?.fleet.checkNow(targetID: id) }
                },
                onCopy: { [weak self] id in self?.copyDiagnostics(id: id) },
                onRefreshFullHearth: { [weak self] id in
                    Task { await self?.fullHearthBridge.refresh(targetID: id) }
                },
                onConnectFullHearth: onConnectFullHearth,
                onOpenSettings: onOpenSettings,
                onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Hearth Monitor Details"
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 680, height: 440)
            window.setContentSize(NSSize(width: 780, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    private func copyDiagnostics(id: UUID) {
        guard let target = fleet.targets.first(where: { $0.id == id }) else { return }
        let report = MonitorDiagnosticsText.report(
            target: target,
            snapshot: fleet.snapshots[id],
            fullHearth: fullHearthBridge.snapshots[id])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

struct MonitorDiagnosticsView: View {
    @ObservedObject var model: MonitorDiagnosticsModel
    @ObservedObject var fleet: MonitorFleetCoordinator
    @ObservedObject var fullHearthBridge: FullHearthBridgeCoordinator
    let onCheck: (UUID) -> Void
    let onCopy: (UUID) -> Void
    let onRefreshFullHearth: (UUID) -> Void
    let onConnectFullHearth: (UUID) -> Void
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(fleet.targets, selection: $model.selectedID) { target in
                    HStack(spacing: 9) {
                        if let snapshot = fleet.snapshots[target.id] {
                            Image(systemName: MonitorPresentation.symbol(snapshot))
                                .foregroundStyle(stateColor(snapshot))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.name).fontWeight(.medium)
                            if let snapshot = fleet.snapshots[target.id] {
                                Text(MonitorPresentation.title(snapshot))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(target.id)
                }
                .frame(minWidth: 190, idealWidth: 220)

                if let target = selectedTarget,
                   let snapshot = fleet.snapshots[target.id] {
                    RunnerDetails(
                        target: target,
                        snapshot: snapshot,
                        fullHearth: fullHearthBridge.snapshots[target.id],
                        isChecking: fleet.checkingTargetIDs.contains(target.id),
                        isCheckingFullHearth: fullHearthBridge.checkingTargetIDs.contains(target.id),
                        onCheck: { onCheck(target.id) },
                        onCopy: { onCopy(target.id) },
                        onRefreshFullHearth: { onRefreshFullHearth(target.id) },
                        onConnectFullHearth: { onConnectFullHearth(target.id) })
                } else {
                    ContentUnavailableView(
                        "Select a runner",
                        systemImage: "waveform.path.ecg",
                        description: Text("Choose a runner to see its latest check."))
                }
            }
            Divider()
            HStack {
                Label("Attached monitoring only. Monitor never restarts or changes a runner.",
                      systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings…", action: onOpenSettings)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var selectedTarget: MonitorTarget? {
        guard let selectedID = model.selectedID else { return fleet.targets.first }
        return fleet.targets.first(where: { $0.id == selectedID }) ?? fleet.targets.first
    }

    private func stateColor(_ snapshot: MonitorSnapshot) -> Color {
        switch snapshot.phase {
        case .healthy: return .green
        case .busy: return .blue
        case .down: return .red
        case .checking where snapshot.failure != nil: return .orange
        case .checking: return .secondary
        }
    }
}

private struct RunnerDetails: View {
    let target: MonitorTarget
    let snapshot: MonitorSnapshot
    let fullHearth: FullHearthBridgeSnapshot?
    let isChecking: Bool
    let isCheckingFullHearth: Bool
    let onCheck: () -> Void
    let onCopy: () -> Void
    let onRefreshFullHearth: () -> Void
    let onConnectFullHearth: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: MonitorPresentation.symbol(snapshot))
                        .font(.system(size: 30))
                        .foregroundStyle(stateColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.name).font(.title2.weight(.semibold))
                        Text(MonitorPresentation.title(snapshot))
                            .font(.headline)
                            .foregroundStyle(stateColor)
                        Text(MonitorPresentation.detail(snapshot))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                GroupBox("Latest check") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        detailRow("Runner", target.runnerKind.displayName)
                        detailRow("Endpoint", "\(target.scheme)://\(target.host):\(target.port)")
                        detailRow("Checked", MonitorPresentation.relative(snapshot.checkedAt))
                        if let checkedAt = snapshot.checkedAt {
                            detailRow("Exact time", checkedAt.formatted(date: .abbreviated, time: .standard))
                        }
                        if snapshot.isServing, let healthySince = snapshot.healthySince {
                            detailRow("Healthy for", MonitorPresentation.duration(Date().timeIntervalSince(healthySince)))
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Inference wedge detection") {
                    VStack(alignment: .leading, spacing: 6) {
                        if target.normalizedProbeModel == nil {
                            Text("Off (API health only)")
                            Text("Enable a one-token check in Settings to detect a GPU or inference engine that is wedged while HTTP still answers.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label(deepProbeText, systemImage: deepProbeSymbol)
                                .foregroundStyle(deepProbeColor)
                            Text("Model: \(target.normalizedProbeModel ?? "")")
                                .font(.callout.monospaced())
                            Text("Last run: \(MonitorPresentation.relative(snapshot.deepProbeLastAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Resident models") {
                    VStack(alignment: .leading, spacing: 6) {
                        if snapshot.residentModels.isEmpty {
                            Text("None reported")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(snapshot.residentModels.enumerated()), id: \.offset) { _, model in
                                HStack {
                                    Text(model.name).font(.callout.monospaced())
                                    Spacer()
                                    if let size = model.sizeBytes {
                                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .memory))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if let note = snapshot.modelsNote {
                            Text(note).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Full Hearth recovery") {
                    VStack(alignment: .leading, spacing: 8) {
                        if target.fullHearth == nil {
                            Text("Not connected")
                            Text("Optionally connect the separately installed full Hearth to see managed restart and GPU-wedge recovery context. Direct monitoring works without it.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Connect Full Hearth…", action: onConnectFullHearth)
                        } else if let fullHearth {
                            Label(fullHearth.message, systemImage: fullHearthSymbol(fullHearth))
                                .foregroundStyle(fullHearthColor(fullHearth))
                                .fixedSize(horizontal: false, vertical: true)
                            if let status = fullHearth.status {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                    detailRow("Supervisor phase", status.phase)
                                    detailRow("Recovery mode", status.mode ?? "Not reported")
                                    detailRow("Restarts", String(status.restartCount))
                                    if let category = status.lastRestartCategory {
                                        detailRow("Last restart", category)
                                    }
                                    if let memory = status.memoryUsedPercent {
                                        detailRow("System memory", "\(memory)% used")
                                    }
                                    if let thermal = status.thermal {
                                        detailRow("Thermal", thermal)
                                    }
                                    detailRow("Credential", credentialText(status))
                                }
                                if status.credentialAccess != "statusOnly" {
                                    Label("Use a status-only token from current full Hearth for least privilege.",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            HStack {
                                Button("Refresh", action: onRefreshFullHearth)
                                    .disabled(isCheckingFullHearth)
                                if isCheckingFullHearth { ProgressView().controlSize(.small) }
                                Button("Connection…", action: onConnectFullHearth)
                            }
                        } else {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Checking full Hearth…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Check Now", action: onCheck).disabled(isChecking)
                    if isChecking { ProgressView().controlSize(.small) }
                    Button("Copy Diagnostics", systemImage: "doc.on.doc", action: onCopy)
                    Spacer()
                }
            }
            .padding(22)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var stateColor: Color {
        switch snapshot.phase {
        case .healthy: return .green
        case .busy: return .blue
        case .down: return .red
        case .checking where snapshot.failure != nil: return .orange
        case .checking: return .secondary
        }
    }

    private var deepProbeText: String {
        switch snapshot.deepProbeLastSucceeded {
        case .some(true): return "Last inference check passed"
        case .some(false): return "Last inference check failed"
        case .none: return "Configured; waiting for its first run"
        }
    }

    private var deepProbeSymbol: String {
        switch snapshot.deepProbeLastSucceeded {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "circle.dotted"
        }
    }

    private var deepProbeColor: Color {
        switch snapshot.deepProbeLastSucceeded {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    private func fullHearthSymbol(_ value: FullHearthBridgeSnapshot) -> String {
        switch value.phase {
        case .connected where value.hasManagedRecovery: return "checkmark.shield.fill"
        case .connected: return "eye.circle"
        case .checking: return "circle.dotted"
        case .unavailable, .unauthorized, .credentialMissing, .runnerMismatch:
            return "exclamationmark.triangle.fill"
        }
    }

    private func fullHearthColor(_ value: FullHearthBridgeSnapshot) -> Color {
        switch value.phase {
        case .connected where value.hasManagedRecovery: return .green
        case .connected: return .orange
        case .checking: return .secondary
        case .unavailable, .unauthorized, .credentialMissing, .runnerMismatch: return .orange
        }
    }

    private func credentialText(_ status: FullHearthStatus) -> String {
        switch status.credentialAccess {
        case "statusOnly": return "Status only"
        case "control": return "Full control (not recommended)"
        default: return "Scope not reported"
        }
    }
}
