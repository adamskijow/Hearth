// SPDX-License-Identifier: MIT

import AppKit
import Combine
import CryptoKit
import HearthMonitorCore
import SupervisorCore
import SwiftUI

@MainActor
final class FullHearthPairingModel: ObservableObject {
    @Published var scheme: String
    @Published var host: String
    @Published var portText: String
    @Published var token: String
    @Published var allowBroadCredential = false
    @Published private(set) var isWorking = false
    @Published private(set) var feedback = ""
    @Published private(set) var feedbackIsError = false
    @Published private(set) var testedStatus: FullHearthStatus?

    private let target: MonitorTarget
    private let client: FullHearthClient
    private var verifiedFingerprint: Data?
    private var testTask: Task<Void, Never>?

    init(target: MonitorTarget, token: String, client: FullHearthClient) {
        self.target = target
        let endpoint = target.fullHearth ?? FullHearthEndpoint(
            scheme: MonitorTarget.isLoopbackHost(target.host) ? "http" : target.scheme,
            host: target.host,
            port: 11435)
        scheme = endpoint.scheme
        host = endpoint.host
        portText = String(endpoint.port)
        self.token = token
        self.client = client
    }

    var endpoint: FullHearthEndpoint {
        FullHearthEndpoint(
            scheme: scheme,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    var normalizedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationIssues: [String] {
        var issues = endpoint.validationIssues
        if normalizedToken.count < 16 {
            issues.append("Paste a status token that is at least 16 characters.")
        } else if normalizedToken.utf8.count > 4096 {
            issues.append("The status token is unexpectedly large.")
        }
        return issues
    }

    var isVerified: Bool { verifiedFingerprint == fingerprint }
    var needsRetest: Bool { verifiedFingerprint != nil && !isVerified }
    var hasLeastPrivilege: Bool { testedStatus?.credentialAccess == "statusOnly" }
    var needsBroadCredentialConsent: Bool {
        isVerified && !hasLeastPrivilege
    }
    var canSave: Bool {
        validationIssues.isEmpty
            && isVerified
            && (hasLeastPrivilege || allowBroadCredential)
    }

    var broadCredentialExplanation: String {
        if testedStatus?.credentialAccess == "control" {
            return "This is a full-control token. Monitor only reads status, but anyone who obtains the token could start, stop, or restart the runner. Prefer a status-only token from full Hearth Settings."
        }
        return "This full Hearth version does not report token scope. Monitor only reads status, but cannot prove the token is read-only. Update full Hearth and create a status-only token when possible."
    }

    func test() {
        guard validationIssues.isEmpty else {
            feedback = validationIssues.first ?? "Check the connection values."
            feedbackIsError = true
            return
        }
        let testedEndpoint = endpoint
        let testedToken = normalizedToken
        let testedFingerprint = fingerprint
        testTask?.cancel()
        isWorking = true
        feedback = "Authenticating with full Hearth…"
        feedbackIsError = false
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await self.client.status(
                    endpoint: testedEndpoint,
                    token: testedToken)
                guard !Task.isCancelled, self.fingerprint == testedFingerprint else {
                    self.feedback = "The connection values changed during the test. Test again."
                    self.feedbackIsError = true
                    self.isWorking = false
                    return
                }
                let statusRunner = status.runner.lowercased()
                guard RunnerKind.knownConfigStrings.contains(statusRunner),
                      RunnerKind(fromConfigString: statusRunner) == self.target.runnerKind else {
                    self.testedStatus = status
                    self.feedback = "Full Hearth reports \(status.runner), but this watched target is \(self.target.runnerKind.displayName). Pair the matching supervisor."
                    self.feedbackIsError = true
                    self.isWorking = false
                    return
                }
                self.testedStatus = status
                self.verifiedFingerprint = testedFingerprint
                self.allowBroadCredential = false
                if status.credentialAccess == "statusOnly" {
                    self.feedback = status.isManaged == true
                        ? "Connected with a read-only token. Full Hearth manages recovery for this runner."
                        : "Connected with a read-only token. Review the recovery mode below."
                } else {
                    self.feedback = "Connected, but the credential is not confirmed read-only."
                }
                self.feedbackIsError = false
            } catch {
                guard !Task.isCancelled else { return }
                self.testedStatus = nil
                self.verifiedFingerprint = nil
                self.feedback = error.localizedDescription
                self.feedbackIsError = true
            }
            self.isWorking = false
        }
    }

    func waitForTest() async { await testTask?.value }

    func reportSaveError(_ error: Error) {
        feedback = "Could not save the connection: \(error.localizedDescription)"
        feedbackIsError = true
    }

    func cancel() {
        testTask?.cancel()
        testTask = nil
        isWorking = false
    }

    private var fingerprint: Data {
        let input = [scheme, host, portText, normalizedToken].joined(separator: "\u{0}")
        return Data(SHA256.hash(data: Data(input.utf8)))
    }
}

@MainActor
final class FullHearthPairingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: FullHearthPairingModel
    private let hasExistingPairing: Bool
    private let onSave: (FullHearthEndpoint, String) throws -> Void
    private let onDisconnect: () throws -> Void
    private let onClose: () -> Void

    init(target: MonitorTarget,
         token: String,
         client: FullHearthClient,
         onSave: @escaping (FullHearthEndpoint, String) throws -> Void,
         onDisconnect: @escaping () throws -> Void,
         onClose: @escaping () -> Void = {}) {
        model = FullHearthPairingModel(target: target, token: token, client: client)
        hasExistingPairing = target.fullHearth != nil
        self.onSave = onSave
        self.onDisconnect = onDisconnect
        self.onClose = onClose
        super.init()
    }

    func show() {
        if window == nil {
            let view = FullHearthPairingView(
                model: model,
                hasExistingPairing: hasExistingPairing,
                onSave: { [weak self] in self?.save() },
                onDisconnect: { [weak self] in self?.disconnect() },
                onCancel: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Connect Full Hearth"
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 560, height: 520)
            window.setContentSize(NSSize(width: 600, height: 650))
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
        model.cancel()
        onClose()
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    private func save() {
        do {
            try onSave(model.endpoint, model.normalizedToken)
            window?.close()
        } catch {
            model.reportSaveError(error)
        }
    }

    private func disconnect() {
        do {
            try onDisconnect()
            window?.close()
        } catch {
            model.reportSaveError(error)
        }
    }
}

struct FullHearthPairingView: View {
    @ObservedObject var model: FullHearthPairingModel
    let hasExistingPairing: Bool
    let onSave: () -> Void
    let onDisconnect: () -> Void
    let onCancel: () -> Void
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 13) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 30)).foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect full Hearth").font(.title2.weight(.semibold))
                            Text("Optional. Monitor keeps checking the runner directly; this read-only connection shows whether full Hearth is providing automatic recovery, restart history, memory, and thermal context.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    GroupBox("Prepare full Hearth") {
                        Text("In the separately installed full Hearth app, open Settings → Remote control, enable the endpoint, then create a Status-only token named “hearth-monitor”. Paste that token below. Monitor never sends start, stop, or restart commands.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(6)
                    }

                    GroupBox("Status connection") {
                        Grid(alignment: .leading, horizontalSpacing: 13, verticalSpacing: 10) {
                            GridRow {
                                Text("Connection")
                                Picker("", selection: $model.scheme) {
                                    Text("HTTP").tag("http")
                                    Text("HTTPS").tag("https")
                                }
                                .pickerStyle(.segmented).labelsHidden()
                                .accessibilityLabel("Full Hearth connection security")
                            }
                            GridRow {
                                Text("Host")
                                TextField("127.0.0.1", text: $model.host)
                            }
                            GridRow {
                                Text("Port")
                                TextField("11435", text: $model.portText).frame(maxWidth: 120)
                            }
                            GridRow {
                                Text("Status token")
                                SecureField("Paste the status-only bearer token", text: $model.token)
                                    .textContentType(.password)
                                    .accessibilityLabel("Full Hearth status token")
                            }
                        }
                        .padding(6)
                        if let warning = model.endpoint.tokenTransportWarning {
                            Label(warning, systemImage: "lock.open.trianglebadge.exclamationmark")
                                .font(.caption).foregroundStyle(.orange)
                                .padding(6)
                        }
                        HStack {
                            Button("Test Read-Only Connection") { model.test() }
                                .disabled(model.isWorking || !model.validationIssues.isEmpty)
                            if model.isWorking { ProgressView().controlSize(.small) }
                            if model.isVerified {
                                Label("Authenticated", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if model.needsRetest {
                                Label("Retest after changes", systemImage: "arrow.clockwise.circle")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                        .padding(6)
                    }

                    if let status = model.testedStatus {
                        GroupBox("Verified full Hearth") {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(recoveryText(status), systemImage: recoverySymbol(status))
                                    .foregroundStyle(recoveryColor(status))
                                Text("Runner: \(status.runner) · phase: \(status.phase) · \(status.restartCount) restart\(status.restartCount == 1 ? "" : "s") this session")
                                    .font(.callout).foregroundStyle(.secondary)
                                if status.rebootOnWedge == true {
                                    Label(rebootEscalationText(status), systemImage: "bolt.shield")
                                        .font(.callout)
                                }
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if model.needsBroadCredentialConsent {
                        GroupBox("Credential scope warning") {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(model.broadCredentialExplanation,
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                Toggle("Store this broader credential anyway", isOn: $model.allowBroadCredential)
                            }
                            .padding(6)
                        }
                    }
                }
                .padding(22)
            }
            Divider()
            VStack(spacing: 8) {
                if !model.feedback.isEmpty {
                    HStack {
                        Image(systemName: model.feedbackIsError ? "xmark.circle.fill" : "info.circle")
                            .foregroundStyle(model.feedbackIsError ? Color.red : Color.secondary)
                        Text(model.feedback)
                            .font(.callout)
                            .foregroundStyle(model.feedbackIsError ? Color.red : Color.secondary)
                        Spacer()
                    }
                }
                HStack {
                    if hasExistingPairing {
                        Button("Disconnect…", role: .destructive) { confirmingDisconnect = true }
                    }
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Save Connection", action: onSave)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSave || model.isWorking)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .alert("Disconnect full Hearth?", isPresented: $confirmingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive, action: onDisconnect)
        } message: {
            Text("The status token will be deleted from Keychain. Direct runner monitoring and incident history continue.")
        }
    }

    private func recoveryText(_ status: FullHearthStatus) -> String {
        switch status.isManaged {
        case true: return "Managed recovery is active"
        case false: return "Full Hearth is attached-only"
        case nil: return "Recovery mode is not reported by this version"
        }
    }

    private func recoverySymbol(_ status: FullHearthStatus) -> String {
        status.isManaged == true ? "checkmark.shield.fill" : "eye.circle"
    }

    private func rebootEscalationText(_ status: FullHearthStatus) -> String {
        switch status.isManaged {
        case true:
            return "GPU/driver reboot escalation is configured in full Hearth."
        case false:
            return "GPU/driver reboot escalation is configured, but inactive while full Hearth is attached-only."
        case nil:
            return "GPU/driver reboot escalation is configured; this full Hearth version does not report whether recovery is active."
        }
    }

    private func recoveryColor(_ status: FullHearthStatus) -> Color {
        status.isManaged == true ? .green : .orange
    }
}
