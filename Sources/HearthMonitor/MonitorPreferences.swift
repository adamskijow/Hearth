// SPDX-License-Identifier: MIT

import AppKit
import Combine
import HearthMonitorCore
import SupervisorCore
import SwiftUI

@MainActor
final class MonitorPreferencesModel: ObservableObject {
    @Published var settings: MonitorSettings
    @Published var selectedID: UUID?
    @Published var problem: String?
    @Published var notificationPermission: MonitorNotificationPermission = .notDetermined
    @Published var loginItemState: MonitorLoginItem.State = .off
    @Published var generalStatus = ""
    @Published var generalBusy = false

    init(settings: MonitorSettings, problem: String?) {
        self.settings = settings
        selectedID = settings.selectedTargetID ?? settings.targets.first?.id
        self.problem = problem
    }

    var selectedTarget: MonitorTarget? {
        guard let selectedID else { return nil }
        return settings.targets.first(where: { $0.id == selectedID })
    }
}

@MainActor
final class MonitorPreferencesController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var editor: MonitorTargetEditorController?
    private let model: MonitorPreferencesModel
    private let http: any HTTPClient
    private let notifier: MonitorLocalNotifier
    private let onChange: (MonitorSettings) throws -> Void

    init(settings: MonitorSettings,
         problem: String?,
         http: any HTTPClient,
         notifier: MonitorLocalNotifier,
         onChange: @escaping (MonitorSettings) throws -> Void) {
        model = MonitorPreferencesModel(settings: settings, problem: problem)
        self.http = http
        self.notifier = notifier
        self.onChange = onChange
        super.init()
    }

    func show(settings: MonitorSettings, problem: String?) {
        model.settings = settings
        model.selectedID = settings.selectedTargetID ?? settings.targets.first?.id
        model.problem = problem
        if window == nil {
            let view = MonitorPreferencesView(
                model: model,
                onSelect: { [weak self] id in self?.select(id) },
                onAdd: { [weak self] in self?.addTarget() },
                onEdit: { [weak self] in self?.editTarget() },
                onRemove: { [weak self] in self?.removeTarget() },
                onSetAppleEnabled: { [weak self] enabled in self?.setAppleEnabled(enabled) },
                onSetFunctionalChecks: { [weak self] enabled in self?.setFunctionalChecks(enabled) },
                onSetAppleInterval: { [weak self] interval in self?.setAppleInterval(interval) },
                onSetAlerts: { [weak self] enabled in self?.setAlerts(enabled) },
                onResumeAlerts: { [weak self] in self?.resumeAlerts() },
                onSetLogin: { [weak self] enabled in self?.setLogin(enabled) },
                onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Hearth Monitor Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 540, height: 520)
            window.setContentSize(NSSize(width: 640, height: 720))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshGeneralState()
    }

    func windowWillClose(_ notification: Notification) {
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    func settingsDidChange(_ settings: MonitorSettings) {
        model.settings = settings
        if let selectedID = model.selectedID,
           settings.targets.contains(where: { $0.id == selectedID }) {
            model.selectedID = selectedID
        } else {
            model.selectedID = settings.selectedTargetID ?? settings.targets.first?.id
        }
        model.problem = nil
    }

    private func select(_ id: UUID) {
        model.selectedID = id
        var updated = model.settings
        updated.selectedTargetID = id
        persist(updated)
    }

    private func addTarget() {
        let target = MonitorTarget()
        editor = MonitorTargetEditorController(
            target: target,
            http: http,
            onSave: { [weak self] target in
                guard let self else { return }
                var updated = self.model.settings
                updated.upsert(target)
                try self.onChange(updated)
                self.model.settings = updated
                self.model.selectedID = target.id
                self.model.problem = nil
            },
            onClose: { [weak self] in self?.editor = nil })
        editor?.show(title: "Add Runner", discoverOnOpen: true)
    }

    private func editTarget() {
        guard let target = model.selectedTarget else { return }
        editor = MonitorTargetEditorController(
            target: target,
            http: http,
            onSave: { [weak self] target in
                guard let self else { return }
                var updated = self.model.settings
                updated.upsert(target)
                try self.onChange(updated)
                self.model.settings = updated
                self.model.selectedID = target.id
                self.model.problem = nil
            },
            onClose: { [weak self] in self?.editor = nil })
        editor?.show(title: "Edit Runner", discoverOnOpen: false)
    }

    private func removeTarget() {
        guard let id = model.selectedID else { return }
        var updated = model.settings
        guard updated.removeTarget(id: id) else { return }
        persist(updated)
    }

    private func setAppleEnabled(_ enabled: Bool) {
        var updated = model.settings
        updated.appleModel.enabled = enabled
        persist(updated)
    }

    private func setFunctionalChecks(_ enabled: Bool) {
        var updated = model.settings
        updated.appleModel.functionalChecksEnabled = enabled
        persist(updated)
    }

    private func setAppleInterval(_ interval: TimeInterval) {
        var updated = model.settings
        updated.appleModel.checkIntervalSeconds = interval
        persist(updated)
    }

    private func setAlerts(_ enabled: Bool) {
        if !enabled {
            var updated = model.settings
            updated.alertsEnabled = false
            updated.alertsSnoozedUntil = nil
            persist(updated)
            model.generalStatus = "Outage alerts are off. Health checks and history continue."
            return
        }
        model.generalBusy = true
        model.generalStatus = "Requesting notification permission…"
        Task { [weak self] in
            guard let self else { return }
            let permission = await self.notifier.requestPermission()
            self.model.notificationPermission = permission
            self.model.generalBusy = false
            guard permission == .enabled else {
                self.model.generalStatus = "Notifications are not allowed in System Settings. Monitoring still continues."
                return
            }
            var updated = self.model.settings
            updated.alertsEnabled = true
            self.persist(updated)
            self.model.generalStatus = "Outage and recovery alerts are on."
        }
    }

    private func resumeAlerts() {
        var updated = model.settings
        updated.alertsSnoozedUntil = nil
        persist(updated)
        model.generalStatus = "Alerts resumed."
    }

    private func setLogin(_ enabled: Bool) {
        do {
            try MonitorLoginItem.setEnabled(enabled)
            model.loginItemState = MonitorLoginItem.state
            switch model.loginItemState {
            case .on: model.generalStatus = "Hearth Monitor will open at login."
            case .off: model.generalStatus = "Hearth Monitor will not open at login."
            case .requiresApproval:
                model.generalStatus = "macOS requires approval in System Settings → General → Login Items."
            case .unavailable:
                model.generalStatus = "Start at Login is unavailable until the app is installed in Applications."
            }
        } catch {
            model.loginItemState = MonitorLoginItem.state
            model.generalStatus = "Could not change Start at Login: \(error.localizedDescription)"
        }
    }

    private func refreshGeneralState() {
        model.loginItemState = MonitorLoginItem.state
        Task { [weak self] in
            guard let self else { return }
            self.model.notificationPermission = await self.notifier.permission()
        }
    }

    private func persist(_ updated: MonitorSettings) {
        do {
            try onChange(updated)
            model.settings = updated
            model.selectedID = updated.selectedTargetID
            model.problem = nil
        } catch {
            model.selectedID = model.settings.selectedTargetID
            model.problem = "Could not save settings: \(error.localizedDescription)"
        }
    }
}

struct MonitorPreferencesView: View {
    @ObservedObject var model: MonitorPreferencesModel
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onSetAppleEnabled: (Bool) -> Void
    let onSetFunctionalChecks: (Bool) -> Void
    let onSetAppleInterval: (TimeInterval) -> Void
    let onSetAlerts: (Bool) -> Void
    let onResumeAlerts: () -> Void
    let onSetLogin: (Bool) -> Void
    let onDone: () -> Void
    @State private var showingRemoveConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                general
                appleIntelligence
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Watched runners").font(.title2.weight(.semibold))
                        Text("Monitor checks these endpoints but never controls their processes.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if model.settings.targets.isEmpty {
                    ContentUnavailableView(
                        "No runners yet",
                        systemImage: "waveform.path.ecg",
                        description: Text("Add an existing local or remote AI runner to begin monitoring."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                      ForEach(model.settings.targets) { target in
                        Button {
                            onSelect(target.id)
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: model.selectedID == target.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedID == target.id ? .orange : .secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(target.name).fontWeight(.medium)
                                    Text("\(target.runnerKind.displayName) · \(target.scheme)://\(target.host):\(target.port)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(target.normalizedProbeModel == nil
                                         ? "API health" : "API + inference wedge detection")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if target.fullHearth != nil {
                                        Text("Full Hearth recovery status connected")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                        .accessibilityLabel("\(target.name), \(target.runnerKind.displayName), \(model.selectedID == target.id ? "selected" : "not selected")")
                        if target.id != model.settings.targets.last?.id { Divider() }
                      }
                    }
                    .padding(.horizontal, 10)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Button("Add Runner", systemImage: "plus", action: onAdd)
                    Button("Edit", action: onEdit)
                        .disabled(model.selectedTarget == nil)
                    Button("Remove", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                    .disabled(model.selectedTarget == nil)
                    Spacer()
                }
              }
              .padding(20)
            }
            Divider()
            HStack {
                Text("Settings are stored inside Hearth Monitor's App Sandbox container.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
        }
        .alert("Remove this runner?", isPresented: $showingRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text("Existing incident history for this runner remains available in History.")
        }
    }

    private var general: some View {
        GroupBox("General") {
            VStack(alignment: .leading, spacing: 11) {
                Toggle("Outage and recovery alerts", isOn: Binding(
                    get: { model.settings.alertsEnabled },
                    set: { value in onSetAlerts(value) }))
                    .disabled(model.generalBusy)
                Text(notificationHelp)
                    .font(.caption)
                    .foregroundStyle(notificationHelpColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let until = model.settings.alertsSnoozedUntil, until > Date() {
                    HStack {
                        Label("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))",
                              systemImage: "bell.slash")
                            .font(.callout)
                        Button("Resume", action: onResumeAlerts).controlSize(.small)
                    }
                }
                Divider()
                Toggle("Open Hearth Monitor at login", isOn: Binding(
                    get: { model.loginItemState == .on },
                    set: { value in onSetLogin(value) }))
                    .disabled(model.loginItemState == .unavailable)
                if model.loginItemState == .requiresApproval {
                    Text("Approval is required in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !model.generalStatus.isEmpty {
                    Text(model.generalStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appleIntelligence: some View {
        GroupBox("Apple Intelligence") {
            VStack(alignment: .leading, spacing: 11) {
                Toggle("Monitor Apple Intelligence availability", isOn: Binding(
                    get: { model.settings.appleModel.enabled },
                    set: { onSetAppleEnabled($0) }))
                Text("Uses Apple's public Foundation Models availability state. On unsupported Macs, Local AI Runner monitoring remains available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle("Run private functional health checks", isOn: Binding(
                    get: { model.settings.appleModel.functionalChecksEnabled },
                    set: { onSetFunctionalChecks($0) }))
                    .disabled(!model.settings.appleModel.enabled)
                Text("Generates one tiny fixed response on this Mac. No prompt or response is retained. Two failures are required before Hearth records or alerts on an incident.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Functional check interval")
                    Spacer()
                    Picker("Functional check interval", selection: Binding(
                        get: { model.settings.appleModel.checkIntervalSeconds },
                        set: { onSetAppleInterval($0) })) {
                        Text("15 minutes").tag(TimeInterval(900))
                        Text("30 minutes").tag(TimeInterval(1_800))
                        Text("1 hour").tag(TimeInterval(3_600))
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                .disabled(!model.settings.appleModel.enabled
                          || !model.settings.appleModel.functionalChecksEnabled)
                Label("Checks pause during sleep, Low Power Mode, and serious thermal pressure.",
                      systemImage: "leaf")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notificationHelp: String {
        if !model.settings.alertsEnabled {
            if model.notificationPermission == .denied {
                return "Notifications are denied in System Settings. Monitoring and history still work."
            }
            return "Off by default. Enabling asks macOS for permission with this context."
        }
        switch model.notificationPermission {
        case .enabled: return "One alert per confirmed incident, plus recovery. Single missed checks never alert."
        case .denied: return "Enabled here, but blocked in System Settings. Monitoring and history still work."
        case .notDetermined: return "Waiting for macOS notification permission."
        }
    }

    private var notificationHelpColor: Color {
        model.settings.alertsEnabled && model.notificationPermission == .denied ? .orange : .secondary
    }
}
