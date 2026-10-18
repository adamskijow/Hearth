// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import SupervisorCore

/// Hosts the Preferences window in the accessory (menubar) app. The window edits
/// the same config.json the file workflow uses; Save writes the file and triggers
/// a live reload, so nothing requires a restart.
@MainActor
final class PreferencesController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: PreferencesModel
    private let onSave: (HearthConfig) -> Bool
    /// The config this window started from, so an external change (a file edit
    /// plus SIGHUP, the CLI, a menu switch) can be told apart from the user's own
    /// in-window edits.
    private var baseline: HearthConfig?

    init(config: HearthConfig, onSave: @escaping (HearthConfig) -> Bool) {
        self.model = PreferencesModel(config)
        self.onSave = onSave
        super.init()
    }

    /// Called after a reload applied a config that did not come from this window.
    /// If the user has not edited anything yet, adopt the new values so Save
    /// cannot silently revert them; if they have, warn instead of discarding
    /// either side's changes.
    func externalConfigDidChange(_ new: HearthConfig) {
        guard window?.isVisible == true else {
            model.resetProbeUI()
            model.config = new
            model.baseline = new
            model.probeEnabled = Self.hasProbe(new)
            baseline = new
            return
        }
        if new == model.config {
            model.baseline = new
            baseline = new
            return
        }
        if model.config == baseline {
            model.resetProbeUI()
            model.config = new
            model.baseline = new
            model.probeEnabled = Self.hasProbe(new)
            baseline = new
            model.status = "Config changed outside this window; now showing the new values."
        } else {
            model.status = "Config changed outside this window while you were editing; Save will overwrite that change."
        }
    }

    func show(config: HearthConfig) {
        model.resetProbeUI()
        model.config = config
        model.baseline = config
        model.probeEnabled = Self.hasProbe(config)
        baseline = config
        if window == nil {
            let view = PreferencesView(
                model: model,
                onSave: { [weak self] config in
                    guard let self, self.onSave(config) else { return false }
                    self.baseline = config
                    return true
                },
                onClose: { [weak self] in self?.window?.close() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Hearth Preferences"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 560))
            window.contentMinSize = NSSize(width: 520, height: 500)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // Become a regular app while the window is open so it can take focus, then
        // drop back to an accessory (no Dock icon) when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private static func hasProbe(_ config: HearthConfig) -> Bool {
        !(config.probeModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class PreferencesModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case runner = "General", health = "Health", alerts = "Alerts", advanced = "Advanced"
        var id: String { rawValue }
    }
    @Published var page: Page = .runner
    @Published var probeRequestID = UUID()
    @Published var config: HearthConfig
    @Published var baseline: HearthConfig
    @Published var status: String = ""
    @Published var availableProbeModels: [AvailableModel] = []
    @Published var probeStatus: String = ""
    @Published var probeBusy = false
    @Published var probeEnabled: Bool
    init(_ config: HearthConfig) {
        self.config = config
        self.baseline = config
        self.probeEnabled = !(config.probeModel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func save(using persist: (HearthConfig) -> Bool) {
        guard canSave, persist(config) else {
            status = "Could not save. Check folder permissions; your edits are still here."
            return
        }
        baseline = config
        status = "Saved. Reload requested; check the menu for runner status."
    }

    func resetProbeUI() {
        probeRequestID = UUID()
        probeBusy = false
        probeStatus = ""
        availableProbeModels = []
    }

    var blockingDiagnostics: [Diagnostic] {
        ConfigDiagnostics.check(config).filter { $0.severity == .error }
    }

    var canSave: Bool { blockingDiagnostics.isEmpty }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let onSave: (HearthConfig) -> Bool
    let onClose: () -> Void
    @State private var showingEnvEditor = false
    @State private var showingTokensEditor = false
    @State private var showingStatusTokensEditor = false
    @State private var showAdvancedTuning = false
    @State private var showConnectionSettings = false
    @State private var showPhoneAlerts = false
    @State private var showIntegrations = false
    @State private var showDeviceAlerts = false
    @State private var showLogSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $model.page) {
                ForEach(PreferencesModel.Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            // Constrain the form to the space above the fixed footer. Without
            // this boundary, long grouped forms can push Save out of the window.
            GeometryReader { area in
                Form {
                    switch model.page {
                    case .runner: runnerSection
                    case .health: inferenceHealthSection; clientProxySection
                    case .alerts: notificationsSection
                    case .advanced: controlSection; advancedSection; loggingSection
                    }
                }
                .formStyle(.grouped)
                .frame(width: area.size.width, height: area.size.height)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let error = footerBlockingDiagnostic {
                    Text(error.message).foregroundStyle(.red).font(.callout)
                }
                if saveImpact == .restart {
                    Text(model.config.isManaged
                         ? "These changes restart the runner and unload its models."
                         : "These changes restart supervision; the watched runner stays running.")
                        .foregroundStyle(.orange).font(.callout)
                }
                if !model.status.isEmpty {
                    Text(model.status).foregroundStyle(.secondary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Close", action: onClose)
                    Button(saveButtonTitle) {
                        model.save(using: onSave)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave || saveImpact == .none)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 500, minHeight: 500)
        .sheet(isPresented: $showingEnvEditor) {
            EnvEditorView(
                env: model.config.runnerEnv,
                runner: model.config.runner,
                onDone: { model.config.runnerEnv = $0; showingEnvEditor = false },
                onCancel: { showingEnvEditor = false }
            )
        }
        .sheet(isPresented: $showingTokensEditor) {
            TokensEditorView(
                tokens: model.config.controlTokens,
                onDone: { model.config.controlTokens = $0; showingTokensEditor = false },
                onCancel: { showingTokensEditor = false }
            )
        }
        .sheet(isPresented: $showingStatusTokensEditor) {
            TokensEditorView(
                tokens: model.config.controlStatusTokens,
                heading: "Status-only tokens",
                explanation: "Give dashboards a read-only credential. These tokens can read /status and /metrics, but Hearth rejects start, stop, and restart with HTTP 403. Use a unique token per caller so access can be revoked independently.",
                namePlaceholder: "name (e.g. dashboard)",
                onDone: { model.config.controlStatusTokens = $0; showingStatusTokensEditor = false },
                onCancel: { showingStatusTokensEditor = false }
            )
        }
        .task(id: probeTarget) {
            if deepProbeEnabled.wrappedValue {
                await refreshProbeModels()
            }
        }
        .onAppear {
            showPhoneAlerts = !(model.config.ntfyTopic ?? "").isEmpty
            showIntegrations = !(model.config.webhookURL ?? "").isEmpty
                || !(model.config.heartbeatURL ?? "").isEmpty
        }
    }

    private var saveImpact: ConfigReloadImpact {
        ConfigReloadImpact.between(model.baseline, model.config)
    }

    /// The missing managed MLX model is already highlighted beside its field.
    /// Keep the footer for any other blocking problem instead of repeating the
    /// same long message at opposite ends of the window.
    private var footerBlockingDiagnostic: Diagnostic? {
        model.blockingDiagnostics.first { diagnostic in
            !(model.page == .runner
              && model.config.runnerKind == .mlx
              && model.config.isManaged
              && model.config.normalizedMLXModel == nil
              && diagnostic.message.contains("requires mlxModel"))
        }
    }

    private var saveButtonTitle: String {
        guard saveImpact == .restart else { return "Save" }
        return model.config.isManaged ? "Save & Restart Runner" : "Save & Restart Supervision"
    }

    /// A short summary of the configured runner environment for the Preferences row.
    private var envSummary: String {
        let count = model.config.runnerEnv.count
        return count == 0 ? "None" : "\(count) variable\(count == 1 ? "" : "s")"
    }

    /// A short summary of the named control tokens for the Preferences row.
    private var tokensSummary: String {
        let count = model.config.controlTokens.count
        return count == 0 ? "None" : "\(count) token\(count == 1 ? "" : "s")"
    }

    private var statusTokensSummary: String {
        let count = model.config.controlStatusTokens.count
        return count == 0 ? "None" : "\(count) token\(count == 1 ? "" : "s")"
    }

    // MARK: Sections

    @ViewBuilder private var runnerSection: some View {
        Section {
            Picker("Runner", selection: $model.config.runner) {
                Text("Ollama").tag("ollama")
                Text("mlx_lm").tag("mlx")
                Text("LM Studio (watch only)").tag("lmstudio")
                Text("Osaurus (experimental)").tag("osaurus")
            }
            Picker("Supervision", selection: $model.config.mode) {
                Text("Start & recover").tag(ModeKind.managed.rawValue)
                Text("Watch only").tag(ModeKind.attached.rawValue)
            }
            .pickerStyle(.segmented)
            .help("Start & recover lets Hearth run the server. Watch only leaves it under its existing app or service.")
            if model.config.runnerKind == .mlx, model.config.isManaged {
                TextField("Startup model", text: optional(\.mlxModel),
                          prompt: Text("Hugging Face model or local path"))
                if model.config.normalizedMLXModel == nil {
                    Text("Choose a startup model, or use Watch only.")
                        .foregroundStyle(.red).font(.caption)
                }
            }
        } header: { Text("Runner") } footer: {
            Text(model.config.isManaged
                 ? "Hearth starts the server and restarts it if it crashes or stops answering."
                 : "Hearth checks health and alerts you. Your existing app or service handles restarts.")
        }
        Section("Connection") {
            LabeledContent("Server") {
                Text(verbatim: "\(model.config.host):\(model.config.port)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            DisclosureGroup("Connection settings", isExpanded: $showConnectionSettings) {
                TextField("Host", text: $model.config.host)
                    .help("127.0.0.1 keeps the runner on this Mac.")
                TextField("Port", value: $model.config.port, format: .number.grouping(.never))
                if model.config.isManaged {
                    TextField("Executable", text: binaryPath)
                    HStack {
                        Spacer()
                        Button("Detect") {
                            if let found = RunnerLocator.locate(model.config.runner) {
                                binaryPath.wrappedValue = found
                                model.status = "Found \(found)"
                            } else {
                                model.status = "No \(model.config.runner) executable found."
                            }
                        }
                        Button("Choose…") { chooseBinary() }
                    }
                    HStack {
                        Text("Environment")
                        Spacer()
                        Text(envSummary).foregroundStyle(.secondary)
                        Button("Edit…") { showingEnvEditor = true }
                    }
                }
            }
        }
    }

    private var inferenceHealthSection: some View {
        Section {
            Toggle("Check model responses", isOn: deepProbeEnabled)
                .help("Periodically generate one token while the selected model is already resident. This catches a GPU or model hang without loading an idle model just for monitoring.")
            if deepProbeEnabled.wrappedValue {
                if model.availableProbeModels.isEmpty {
                    TextField("Model", text: optional(\.probeModel),
                              prompt: Text("e.g. qwen2.5:0.5b"))
                } else {
                    Picker("Model", selection: optional(\.probeModel)) {
                        Text("Choose your workload model").tag("")
                        ForEach(probeModelOptions) { option in
                            Text(probeModelLabel(option)).tag(option.name)
                        }
                    }
                }
                HStack {
                    Button("Refresh") {
                        Task { await refreshProbeModels() }
                    }
                    Button("Test Model") {
                        Task { await testProbe() }
                    }
                    .disabled(model.probeBusy || (model.config.probeModel ?? "").isEmpty)
                    .help("Runs one token through the client endpoint below. This deliberate test may load the selected model.")
                    if model.probeBusy { ProgressView().controlSize(.small) }
                }
                if !model.probeStatus.isEmpty {
                    Text(model.probeStatus).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Model checks")
        } footer: {
            Text(model.config.makeRunner().reportsLoadedModels
                 ? (!deepProbeEnabled.wrappedValue ? "Check that a loaded model can answer, even when the server API looks healthy."
                    : "Automatic checks only use a loaded model. Test Model can load it; save connection changes first.")
                 : "This runner supports manual tests only; it does not report which models are loaded.")
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        Section {
            Toggle("Notifications on this Mac", isOn: $model.config.localNotifications)
            Toggle("Pause all alerts", isOn: $model.config.notificationsPaused)
            Button("Send Test Notification") { sendTest() }
        } header: { Text("Alerts") } footer: {
            Text("Get notified when the runner goes down or recovers.")
        }
        Section("Optional alerts") {
            DisclosureGroup("Phone alerts", isExpanded: $showPhoneAlerts) {
                TextField("ntfy topic", text: optional(\.ntfyTopic), prompt: Text("Choose a hard-to-guess name"))
                    .help("On the public ntfy server, anyone who knows the topic name can subscribe.")
                TextField("Server", text: $model.config.ntfyServer)
                Text("Subscribe to this topic in the ntfy app on your phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Webhooks & heartbeat", isExpanded: $showIntegrations) {
                TextField("Webhook URL", text: optional(\.webhookURL), prompt: Text("Optional"))
                TextField("Heartbeat URL", text: optional(\.heartbeatURL), prompt: Text("Optional"))
                if !(model.config.heartbeatURL ?? "").isEmpty {
                    number("Heartbeat interval (s)", $model.config.heartbeatIntervalSeconds,
                           help: "Seconds between pings while the runner is healthy.")
                }
                Toggle("Include recent runner logs", isOn: $model.config.alertsIncludeLogTail)
                if model.config.alertsIncludeLogTail {
                    Text("Recent logs are included in alerts. They may contain paths, model names, or request text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Mac temperature & memory", isExpanded: $showDeviceAlerts) {
                Toggle("Thermal alerts", isOn: $model.config.thermalAlerts)
                numberInt("Memory alert (%)", $model.config.memoryAlertPercent,
                          help: "Alert above this system memory usage. Set 0 to disable.")
            }
        }
    }

    private var controlSection: some View {
        Section {
            Toggle("Remote control", isOn: $model.config.controlEnabled)
                .help("Serve a small HTTP API so a phone can check status and start, stop, or restart the runner.")
                .onChange(of: model.config.controlEnabled) { _, enabled in
                    // The endpoint refuses to start without a token, so make one
                    // the moment it is enabled rather than failing silently.
                    if enabled, (model.config.controlToken ?? "").isEmpty {
                        model.config.controlToken = Self.randomToken()
                        model.status = "Generated a control token."
                    }
                }
            if model.config.controlEnabled {
                TextField("Bind host", text: $model.config.controlHost)
                    .help("Address the control endpoint listens on. Use a private or Tailscale address.")
                TextField("Port", value: $model.config.controlPort, format: .number.grouping(.never))
                    .help("Port for the control endpoint.")
                HStack {
                    SecureField("Bearer token", text: optional(\.controlToken),
                              prompt: Text("click Generate, or paste a secret"))
                    Button("Generate") { model.config.controlToken = Self.randomToken() }
                }
                .help("Required secret on every control request. Generate makes a random one.")
                HStack {
                    Text("Named tokens")
                    Spacer()
                    Text(tokensSummary).foregroundStyle(.secondary)
                    Button("Edit Tokens\u{2026}") { showingTokensEditor = true }
                }
                .help("Optional: give each caller its own named token, so start, stop, and restart actions are logged with the caller's name. The bearer token above keeps working and is logged as default.")
                HStack {
                    Text("Status-only tokens")
                    Spacer()
                    Text(statusTokensSummary).foregroundStyle(.secondary)
                    Button("Edit Read-Only Tokens\u{2026}") { showingStatusTokensEditor = true }
                }
                .help("Dashboard access: these tokens can read status and metrics but cannot start, stop, or restart the runner.")
                Button("Copy phone URL") { copyPhoneURL() }
            }

        } header: {
            Text("Remote access")
        } footer: {
            Text("Allow status checks and controls over a private network, such as Tailscale.")
        }
    }

    private var clientProxySection: some View {
        Section {
            Toggle("Route requests through Hearth", isOn: $model.config.metricsProxyEnabled)
            if model.config.metricsProxyEnabled {
                numberInt("Proxy port", $model.config.metricsProxyPort,
                          help: "Your apps use this port instead of the runner port.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.config.metricsProxyEnabled ? "Address for your apps" : "Server address")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(model.config.clientEndpoint).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.config.clientEndpoint, forType: .string)
                        model.status = "Client endpoint copied."
                    }
                    .accessibilityLabel("Copy client endpoint")
                }
            }
        } header: { Text("Client connection") } footer: {
            Text(!model.config.isManaged
                 ? "Watch-only mode reports failures but never restarts the server."
                 : model.config.metricsProxyEnabled
                    ? "Use this address in your apps so Hearth can wait for active requests before inference recovery."
                    : "Without routed requests, inference failures trigger alerts but no automatic restart.")
        }
    }

    private var loggingSection: some View {
        Section {
            DisclosureGroup("Log storage", isExpanded: $showLogSettings) {
                TextField("Rotate after (bytes)", value: $model.config.logMaxBytes, format: .number.grouping(.never))
                TextField("Old files to keep", value: $model.config.logKeepFiles, format: .number.grouping(.never))
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Timing and tuning", isExpanded: $showAdvancedTuning) {
                number("Probe interval", $model.config.probeIntervalSeconds,
                       help: "How often Hearth asks the runner \u{201C}are you still answering?\u{201D} while it is up.")
                number("Probe timeout", $model.config.probeTimeoutSeconds,
                       help: "If the runner does not answer within this many seconds, that check counts as a failure.")
                number("Startup grace", $model.config.startupGraceSeconds,
                       help: "How long a freshly started runner gets to come up before Hearth treats it as failed. Large models load slowly.")
                number("Initial backoff", $model.config.initialBackoffSeconds,
                       help: "Wait before the first restart attempt.")
                number("Backoff multiplier", $model.config.backoffMultiplier,
                       help: "Each failed restart multiplies the wait by this, so a broken runner is not restarted in a tight loop.")
                number("Max backoff", $model.config.maxBackoffSeconds,
                       help: "Upper limit on the wait between restarts.")
                numberInt("Crash loop threshold", $model.config.crashLoopThreshold,
                          help: "This many failures inside the window and Hearth slows down: it keeps retrying, but at the failing retry interval.")
                number("Crash loop window", $model.config.crashLoopWindowSeconds,
                       help: "Time window, in seconds, for counting failures toward the threshold above.")
                number("Failing retry interval", $model.config.failingProbeIntervalSeconds,
                       help: "How often to retry once the runner is failing repeatedly.")
                number("Busy timeout", $model.config.busyTimeoutSeconds,
                       help: "How long an uninterrupted busy (queue full) streak is believed before it is treated as a hang and restarted. A real queue drains; a 503 that never ends is a wedge. Floored at 30.")
                numberInt("Memory limit (MB)", $model.config.runnerMemoryLimitMB,
                          help: "Restart a healthy Hearth-started runner whose resident memory crosses this many megabytes, catching slow memory creep before it wedges. 0 disables the watchdog.")
                numberInt("Too-large model threshold", $model.config.modelOOMThreshold,
                          help: "After a model is resident at this many out-of-memory crashes within the window below, Hearth flags it as likely too large for this Mac (an alert and a status flag), so you switch models instead of crash-looping. 0 disables the check.")
                number("Too-large model window", $model.config.modelOOMWindowSeconds,
                       help: "Time window, in seconds, for counting a model's out-of-memory crashes toward the threshold above.")
                number("Maintenance restart hours", $model.config.maintenanceRestartHours,
                       help: "Optional: restart a long-healthy Hearth-started runner this often. 0 disables it.")
                TextField("Maintenance window", text: optional(\.maintenanceWindow),
                          prompt: Text("optional, e.g. 03:00-06:00"))
                    .help("When set, scheduled maintenance restarts wait for this daily window (24-hour local time), so a routine cycle never lands while people are using the runner.")
                Toggle("Warm models after restart", isOn: $model.config.warmModelsAfterRestart)
                    .help("After a restart, load the models that were resident before it, so the next request does not pay a multi-gigabyte cold start. Does GPU work right after recovery.")
                Toggle("Restart on binary change", isOn: $model.config.restartOnBinaryChange)
                    .help("Restart a Hearth-started runner after its program file changes on disk, for example after a Homebrew upgrade.")
                TextField("Runner user (root daemon)", text: optional(\.runnerUser),
                          prompt: Text("only for the headless root daemon"))
                    .help("Only used by the headless root LaunchDaemon (see docs/running-headless.md); the menubar app ignores it.")
            }
        } header: {
            Text("Recovery")
        }
    }

    private func number(_ label: String, _ binding: Binding<Double>, help: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: binding, format: .number.grouping(.never))
                .frame(width: 90).multilineTextAlignment(.trailing)
        }
        .help(help)
    }

    private func numberInt(_ label: String, _ binding: Binding<Int>, help: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: binding, format: .number.grouping(.never))
                .frame(width: 90).multilineTextAlignment(.trailing)
        }
        .help(help)
    }

    // MARK: Bindings and actions

    /// The binary path for the currently selected runner.
    private var binaryPath: Binding<String> {
        Binding(
            get: { model.config.selectedBinaryPath },
            set: { value in model.config.setSelectedBinaryPath(value) }
        )
    }

    private func optional(_ keyPath: WritableKeyPath<HearthConfig, String?>) -> Binding<String> {
        Binding(
            get: { model.config[keyPath: keyPath] ?? "" },
            set: { model.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var deepProbeEnabled: Binding<Bool> {
        Binding(
            get: { model.probeEnabled },
            set: { enabled in
                model.probeEnabled = enabled
                if enabled {
                    model.probeStatus = "Looking for models on the runner\u{2026}"
                    Task { await refreshProbeModels() }
                } else {
                    model.probeRequestID = UUID()
                    model.probeBusy = false
                    model.config.probeModel = nil
                    model.probeStatus = ""
                }
            })
    }

    private var probeTarget: String {
        "\(model.config.runner)|\(model.config.host)|\(model.config.port)"
    }

    private func probeModelLabel(_ model: AvailableModel) -> String {
        guard let size = model.sizeBytes else { return model.name }
        return "\(model.name) (\(StatusText.byteString(size)))"
    }

    private var probeModelOptions: [AvailableModel] {
        guard let current = model.config.probeModel, !current.isEmpty,
              !model.availableProbeModels.contains(where: { $0.name == current }) else {
            return model.availableProbeModels
        }
        return [AvailableModel(name: current)] + model.availableProbeModels
    }

    @MainActor
    private func refreshProbeModels() async {
        let requestID = UUID()
        model.probeRequestID = requestID
        let target = probeTarget
        model.probeBusy = true
        model.availableProbeModels = []
        defer { if model.probeRequestID == requestID { model.probeBusy = false } }
        do {
            let models = try await RunnerProbeSetup.availableModels(config: model.config)
            guard !Task.isCancelled, target == probeTarget, model.probeRequestID == requestID else { return }
            model.availableProbeModels = models
            guard !models.isEmpty else {
                model.probeStatus = "No models were reported. Install your workload model, then refresh."
                return
            }
            model.probeStatus = "Found \(models.count) models. Choose the one your apps use."

        } catch {
            guard !Task.isCancelled, target == probeTarget, model.probeRequestID == requestID else { return }
            model.availableProbeModels = []
            model.probeStatus = error.localizedDescription
        }
    }

    @MainActor
    private func testProbe() async {
        guard !model.probeBusy,
              let probeModel = model.config.probeModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !probeModel.isEmpty else { return }
        let target = probeTarget
        let endpoint = model.config.clientEndpoint
        let requestID = UUID()
        model.probeRequestID = requestID
        model.probeBusy = true
        model.probeStatus = "Running a one-token inference test\u{2026}"
        defer { if model.probeRequestID == requestID { model.probeBusy = false } }
        do {
            let result = try await RunnerProbeSetup.test(config: model.config, model: probeModel)
            guard target == probeTarget, endpoint == model.config.clientEndpoint,
                  model.config.probeModel == probeModel, model.probeRequestID == requestID else { return }
            model.probeStatus = String(format: "Model responded in %.1f seconds.", result.elapsed)
        } catch {
            guard target == probeTarget, endpoint == model.config.clientEndpoint,
                  model.config.probeModel == probeModel, model.probeRequestID == requestID else { return }
            model.probeStatus = error.localizedDescription
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath.wrappedValue = url.path
        }
    }

    private func sendTest() {
        let note = HearthNotification(level: .info, title: "Hearth test", body: "Notifications are working.", event: .becameHealthy)
        LocalNotifier.post(title: note.title, body: note.body)
        var channels = ["local"]
        if let topic = model.config.ntfyTopic, !topic.isEmpty {
            let notifier = NtfyNotifier(server: model.config.ntfyServer, topic: topic)
            Task { await notifier.notify(note) }
            channels.append("ntfy")
        }
        if let webhook = model.config.webhookURL, !webhook.isEmpty, let url = URL(string: webhook) {
            let notifier = WebhookNotifier(url: url)
            Task { await notifier.notify(note) }
            channels.append("webhook")
        }
        model.status = "Sent test notification (\(channels.joined(separator: ", ")))."
    }

    private func copyPhoneURL() {
        guard let url = PhoneAccess.url(
            tailnetIPv4: NetworkInterfaces.tailnetIPv4(),
            controlHost: ControlHostResolver.resolve(model.config.controlHost),
            controlPort: model.config.controlPort) else {
            model.status = "Bind host is loopback, which a phone cannot reach. Use a Tailscale or private address."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        model.status = "Copied \(url)"
    }

    /// Shared with the named-tokens editor, so every generated secret has the
    /// same shape.
    static func randomToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
