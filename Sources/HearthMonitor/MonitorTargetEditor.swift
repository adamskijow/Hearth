// SPDX-License-Identifier: MIT

import AppKit
import Combine
import HearthMonitorCore
import SupervisorCore
import SwiftUI

@MainActor
final class MonitorTargetEditorModel: ObservableObject {
    enum FeedbackTone { case neutral, success, warning, error }

    @Published var name: String
    @Published var runnerKind: RunnerKind
    @Published var scheme: String
    @Published var host: String
    @Published var portText: String
    @Published var deepProbeEnabled: Bool
    @Published var probeModel: String
    @Published private(set) var candidates: [DiscoveredRunner] = []
    @Published private(set) var availableModels: [AvailableModel] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var feedback = ""
    @Published private(set) var feedbackTone: FeedbackTone = .neutral

    private var base: MonitorTarget
    private let http: any HTTPClient
    private var operationGeneration = 0
    private var operationTask: Task<Void, Never>?
    private var verifiedConnectionFingerprint: String?
    private var verifiedInferenceFingerprint: String?

    init(target: MonitorTarget, http: any HTTPClient) {
        base = target
        name = target.name
        runnerKind = target.runnerKind
        scheme = target.scheme
        host = target.host
        portText = String(target.port)
        deepProbeEnabled = target.normalizedProbeModel != nil
        probeModel = target.normalizedProbeModel ?? ""
        self.http = http
    }

    var target: MonitorTarget {
        var value = base
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.runner = runnerKind.rawValue
        value.scheme = scheme.lowercased()
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let model = probeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        value.probeModel = deepProbeEnabled && !model.isEmpty ? model : nil
        return value
    }

    var validationIssues: [String] {
        var issues = target.validationIssues
        if deepProbeEnabled && target.normalizedProbeModel == nil {
            issues.append("Choose or enter a model for inference wedge detection.")
        }
        return issues
    }

    var isConnectionVerified: Bool {
        verifiedConnectionFingerprint == connectionFingerprint
    }

    var isInferenceVerified: Bool {
        !deepProbeEnabled || verifiedInferenceFingerprint == inferenceFingerprint
    }

    var needsSaveConfirmation: Bool {
        !isConnectionVerified || !isInferenceVerified
    }

    var saveConfirmationMessage: String {
        if deepProbeEnabled && !isInferenceVerified {
            return "The current inference check has not passed. Saving is still useful if the runner is temporarily offline, but Hearth Monitor will report it as down until the configured model answers."
        }
        return "The current address has not passed a connection test. Saving is still useful if the runner is temporarily offline, but check the address carefully."
    }

    var connectionRetestNeeded: Bool {
        verifiedConnectionFingerprint != nil && !isConnectionVerified
    }

    var inferenceRetestNeeded: Bool {
        verifiedInferenceFingerprint != nil && !isInferenceVerified
    }

    func discover() {
        operationGeneration &+= 1
        let generation = operationGeneration
        operationTask?.cancel()
        isWorking = false
        isDiscovering = true
        feedback = "Looking for supported runners on this Mac…"
        feedbackTone = .neutral
        let http = self.http
        operationTask = Task { [weak self] in
            let found = await MonitorDiscovery.discover(http: http)
            guard let self, self.operationGeneration == generation, !Task.isCancelled else { return }
            self.candidates = found
            self.isDiscovering = false
            if found.isEmpty {
                self.feedback = "No local runner answered yet. You can enter an address now and save it even if the runner is offline."
                self.feedbackTone = .neutral
            } else {
                self.feedback = found.count == 1
                    ? "Found one compatible local endpoint. Confirm the runner type before saving."
                    : "Found \(found.count) compatible local endpoints. Confirm the runner type before saving."
                self.feedbackTone = .success
            }
        }
    }

    func useCandidate(_ candidate: DiscoveredRunner) {
        let endpointChanged = runnerKind != candidate.kind
            || host != candidate.host
            || portText != String(candidate.port)
        runnerKind = candidate.kind
        scheme = "http"
        host = candidate.host
        portText = String(candidate.port)
        name = candidate.kind.displayName
        if endpointChanged {
            availableModels = []
            probeModel = ""
        }
        feedback = "Using the \(candidate.kind.displayName) candidate at \(candidate.host):\(candidate.port). Test it to confirm."
        feedbackTone = .neutral
    }

    func useDefaultPort() {
        portText = String(runnerKind.monitorDefaultPort)
    }

    func testConnection() {
        guard validationIssues.filter({ !$0.contains("model for inference") }).isEmpty else {
            reportFirstValidationIssue(ignoringProbeModel: true)
            return
        }
        let checkedTarget = target
        let fingerprint = connectionFingerprint
        startOperation(message: "Testing the runner address…") { [weak self] generation in
            guard let self else { return }
            do {
                let result = try await MonitorProbeSetup.checkConnection(
                    target: checkedTarget,
                    http: self.http)
                guard self.operationIsCurrent(generation), self.connectionFingerprint == fingerprint else {
                    self.reportChangedDuringTest()
                    return
                }
                self.verifiedConnectionFingerprint = fingerprint
                self.feedback = result.isBusy
                    ? "Connected. The runner is busy serving a request, which is healthy."
                    : "Connected successfully."
                self.feedbackTone = .success
            } catch {
                guard self.operationIsCurrent(generation) else { return }
                self.feedback = error.localizedDescription
                self.feedbackTone = .error
            }
        }
    }

    func loadModels() {
        guard validationIssues.filter({ !$0.contains("model for inference") }).isEmpty else {
            reportFirstValidationIssue(ignoringProbeModel: true)
            return
        }
        let checkedTarget = target
        let fingerprint = connectionFingerprint
        startOperation(message: "Reading the runner's model catalog…") { [weak self] generation in
            guard let self else { return }
            do {
                let models = try await MonitorProbeSetup.availableModels(
                    target: checkedTarget,
                    http: self.http)
                guard self.operationIsCurrent(generation), self.connectionFingerprint == fingerprint else {
                    self.reportChangedDuringTest()
                    return
                }
                self.availableModels = models
                if self.probeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let first = models.first {
                    self.probeModel = first.name
                }
                self.feedback = models.isEmpty
                    ? "The runner returned an empty model catalog. You can enter a model name manually."
                    : "Found \(models.count) model\(models.count == 1 ? "" : "s"), smallest first."
                self.feedbackTone = models.isEmpty ? .warning : .success
            } catch {
                guard self.operationIsCurrent(generation) else { return }
                self.feedback = error.localizedDescription
                self.feedbackTone = .error
            }
        }
    }

    func testInference() {
        guard validationIssues.isEmpty else {
            reportFirstValidationIssue(ignoringProbeModel: false)
            return
        }
        let checkedTarget = target
        let fingerprint = inferenceFingerprint
        startOperation(message: "Running one token of inference…") { [weak self] generation in
            guard let self else { return }
            do {
                let result = try await MonitorProbeSetup.testInference(
                    target: checkedTarget,
                    model: checkedTarget.normalizedProbeModel ?? "",
                    http: self.http)
                guard self.operationIsCurrent(generation), self.inferenceFingerprint == fingerprint else {
                    self.reportChangedDuringTest()
                    return
                }
                self.verifiedConnectionFingerprint = self.connectionFingerprint
                self.verifiedInferenceFingerprint = fingerprint
                self.feedback = String(format: "Inference passed in %.2f seconds.", result.elapsed)
                self.feedbackTone = .success
            } catch {
                guard self.operationIsCurrent(generation) else { return }
                self.feedback = error.localizedDescription
                self.feedbackTone = .error
            }
        }
    }

    func reportSaveError(_ error: Error) {
        feedback = "Could not save: \(error.localizedDescription)"
        feedbackTone = .error
    }

    func cancelOperations() {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        isWorking = false
        isDiscovering = false
    }

    /// Lets deterministic UI-model tests wait for the model's current work
    /// without polling wall-clock time.
    func waitForCurrentOperation() async {
        await operationTask?.value
    }

    private var connectionFingerprint: String {
        "\(runnerKind.rawValue)|\(scheme.lowercased())|\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(portText.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private var inferenceFingerprint: String {
        "\(connectionFingerprint)|\(probeModel.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func startOperation(
        message: String,
        operation: @escaping @MainActor (Int) async -> Void
    ) {
        operationGeneration &+= 1
        let generation = operationGeneration
        operationTask?.cancel()
        isDiscovering = false
        isWorking = true
        feedback = message
        feedbackTone = .neutral
        operationTask = Task { [weak self] in
            await operation(generation)
            guard let self, self.operationGeneration == generation else { return }
            self.isWorking = false
        }
    }

    private func operationIsCurrent(_ generation: Int) -> Bool {
        operationGeneration == generation && !Task.isCancelled
    }

    private func reportChangedDuringTest() {
        feedback = "The connection details changed during the test. Test the current values again."
        feedbackTone = .warning
    }

    private func reportFirstValidationIssue(ignoringProbeModel: Bool) {
        let issues = ignoringProbeModel
            ? validationIssues.filter { !$0.contains("model for inference") }
            : validationIssues
        feedback = issues.first ?? "Check the highlighted values."
        feedbackTone = .error
    }
}

@MainActor
final class MonitorTargetEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: MonitorTargetEditorModel
    private let onSave: (MonitorTarget) throws -> Void
    private let onClose: () -> Void

    init(target: MonitorTarget,
         http: any HTTPClient,
         onSave: @escaping (MonitorTarget) throws -> Void,
         onClose: @escaping () -> Void = {}) {
        model = MonitorTargetEditorModel(target: target, http: http)
        self.onSave = onSave
        self.onClose = onClose
        super.init()
    }

    func show(title: String, discoverOnOpen: Bool) {
        if window == nil {
            let view = MonitorTargetEditorView(
                model: model,
                onSave: { [weak self] target in self?.commit(target) },
                onCancel: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = title
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 560, height: 560)
            window.setContentSize(NSSize(width: 620, height: 720))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if discoverOnOpen && model.candidates.isEmpty { model.discover() }
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelOperations()
        onClose()
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    private func commit(_ target: MonitorTarget) {
        do {
            try onSave(target)
            window?.close()
        } catch {
            model.reportSaveError(error)
        }
    }
}

struct MonitorTargetEditorView: View {
    @ObservedObject var model: MonitorTargetEditorModel
    let onSave: (MonitorTarget) -> Void
    let onCancel: () -> Void
    @State private var showingUnverifiedSave = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    discovery
                    connection
                    inference
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .alert("Save without a successful test?", isPresented: $showingUnverifiedSave) {
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel")
            Button("Save Anyway") { onSave(model.target) }
                .accessibilityLabel("Save runner anyway")
        } message: {
            Text(model.saveConfirmationMessage)
        }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Watch an existing AI runner")
                    .font(.title2.weight(.semibold))
                Text("Hearth Monitor checks a runner you already operate. It never starts, stops, or changes that runner.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var discovery: some View {
        GroupBox("Found on this Mac") {
            VStack(alignment: .leading, spacing: 10) {
                if model.isDiscovering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking conventional local ports…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.candidates.isEmpty {
                    Text("No compatible endpoint found yet. The runner may be stopped or use a different port.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.candidates) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(candidate.kind.displayName) candidate")
                                    .fontWeight(.medium)
                                Text("\(candidate.host):\(candidate.port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") { model.useCandidate(candidate) }
                                .accessibilityLabel("Use \(candidate.kind.displayName) at \(candidate.host), port \(candidate.port)")
                        }
                    }
                    Text("Candidate means the endpoint is compatible; confirm the runner type below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Scan Again", systemImage: "arrow.clockwise") { model.discover() }
                    .disabled(model.isDiscovering || model.isWorking)
                    .accessibilityLabel("Scan again for local runners")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var connection: some View {
        GroupBox("Connection") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 11) {
                GridRow {
                    Text("Name")
                    TextField("Studio Mac", text: $model.name)
                        .accessibilityLabel("Runner name")
                }
                GridRow {
                    Text("Runner")
                    Picker("", selection: $model.runnerKind) {
                        ForEach(RunnerKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Runner type")
                    .onChange(of: model.runnerKind) { _, _ in model.useDefaultPort() }
                }
                GridRow {
                    Text("Connection")
                    Picker("", selection: $model.scheme) {
                        Text("HTTP").tag("http")
                        Text("HTTPS").tag("https")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Connection security")
                }
                GridRow {
                    Text("Host")
                    TextField("127.0.0.1", text: $model.host)
                        .textContentType(.URL)
                        .accessibilityLabel("Runner host")
                }
                GridRow {
                    Text("Port")
                    TextField("11434", text: $model.portText)
                        .frame(maxWidth: 120, alignment: .leading)
                        .accessibilityLabel("Runner port")
                }
            }
            .padding(6)

            if let advisory = model.target.transportAdvisory {
                Label(advisory, systemImage: "lock.open.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }

            HStack {
                Button("Test Connection") { model.testConnection() }
                    .disabled(model.isWorking)
                    .accessibilityLabel("Test connection")
                if model.isConnectionVerified {
                    Label("Verified", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if model.connectionRetestNeeded {
                    Label("Retest after changes", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(6)
        }
    }

    private var inference: some View {
        GroupBox("Inference wedge detection") {
            VStack(alignment: .leading, spacing: 11) {
                Toggle("Run a one-token inference check", isOn: $model.deepProbeEnabled)
                    .accessibilityLabel("Run a one-token inference check")
                Text("Optional. Once per minute, Monitor asks the selected model for one token. This catches a GPU or inference engine that is wedged even when its HTTP API still answers. The test can load the model into unified memory/GPU, and the runner decides how long it stays resident.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.deepProbeEnabled {
                    HStack {
                        Button("Find Models") { model.loadModels() }
                            .disabled(model.isWorking)
                            .accessibilityLabel("Find models")
                        if !model.availableModels.isEmpty {
                            Picker("Suggested", selection: $model.probeModel) {
                                ForEach(model.availableModels) { available in
                                    Text(modelLabel(available)).tag(available.name)
                                }
                            }
                        }
                    }
                    TextField("Model name", text: $model.probeModel)
                        .accessibilityLabel("Inference check model")
                    HStack {
                        Button("Test One-Token Inference") { model.testInference() }
                            .disabled(model.isWorking || model.probeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Test one-token inference")
                        if model.isInferenceVerified {
                            Label("Verified", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if model.inferenceRetestNeeded {
                            Label("Retest after changes", systemImage: "arrow.clockwise.circle")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if !model.feedback.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Image(systemName: feedbackSymbol).foregroundStyle(feedbackColor)
                    Text(model.feedback)
                        .font(.callout)
                        .foregroundStyle(model.feedbackTone == .error ? Color.red : Color.secondary)
                    Spacer()
                }
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .accessibilityLabel("Cancel")
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Runner") {
                    if model.needsSaveConfirmation {
                        showingUnverifiedSave = true
                    } else {
                        onSave(model.target)
                    }
                }
                .accessibilityLabel("Save runner")
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking || !model.validationIssues.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var feedbackSymbol: String {
        switch model.feedbackTone {
        case .neutral: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var feedbackColor: Color {
        switch model.feedbackTone {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func modelLabel(_ model: AvailableModel) -> String {
        guard let size = model.sizeBytes else { return model.name }
        return "\(model.name), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
}

enum MonitorWindowActivation {
    @MainActor static func restoreAccessoryWhenAppropriate() {
        Task { @MainActor in
            await Task.yield()
            let visibleWindows = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
            if !visibleWindows { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
