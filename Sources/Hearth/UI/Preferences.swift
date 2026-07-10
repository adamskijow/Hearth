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
    private let onSave: (HearthConfig) -> Void
    /// The config this window started from, so an external change (a file edit
    /// plus SIGHUP, the CLI, a menu switch) can be told apart from the user's own
    /// in-window edits.
    private var baseline: HearthConfig?

    init(config: HearthConfig, onSave: @escaping (HearthConfig) -> Void) {
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
        model.config = config
        model.baseline = config
        model.probeEnabled = Self.hasProbe(config)
        baseline = config
        if window == nil {
            let view = PreferencesView(
                model: model,
                onSave: { [weak self] config in
                    self?.baseline = config
                    self?.onSave(config)
                },
                onClose: { [weak self] in self?.window?.close() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Hearth Preferences"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 500, height: 620))
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
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let onSave: (HearthConfig) -> Void
    let onClose: () -> Void
    @State private var showingEnvEditor = false
    @State private var showingTokensEditor = false
    @State private var showAdvancedTuning = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                runnerSection
                inferenceHealthSection
                notificationsSection
                controlSection
                loggingSection
                advancedSection
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if saveImpact == .restart {
                    Text(model.config.isManaged
                         ? "These changes restart the runner and unload its models."
                         : "These changes restart supervision; the watched runner stays running.")
                        .foregroundStyle(.orange).font(.callout)
                }
                HStack {
                    Text(model.status).foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button("Close", action: onClose)
                    Button(saveButtonTitle) {
                        let impact = saveImpact
                        onSave(model.config)
                        model.baseline = model.config
                        model.status = impact == .live
                            ? "Saved without restarting the runner."
                            : impact == .none ? "No changes to save." : "Saved and reloaded."
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 560)
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
        .task(id: probeTarget) {
            if deepProbeEnabled.wrappedValue {
                await refreshProbeModels(selectSmallestWhenUnset: false)
            }
        }
    }

    private var saveImpact: ConfigReloadImpact {
        ConfigReloadImpact.between(model.baseline, model.config)
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

    // MARK: Sections

    private var runnerSection: some View {
        Section("Runner") {
            Picker("Runner", selection: $model.config.runner) {
                Text("Ollama").tag("ollama")
                Text("LM Studio").tag("lmstudio")
                Text("mlx_lm").tag("mlx")
                Text("Osaurus").tag("osaurus")
            }
            .help("Which local LLM server Hearth supervises.")
            Picker("Mode", selection: $model.config.mode) {
                Text(ModeKind.managed.pickerLabel).tag(ModeKind.managed.rawValue)
                Text(ModeKind.attached.pickerLabel).tag(ModeKind.attached.rawValue)
            }
            .pickerStyle(.segmented)
            .help("Choose whether Hearth starts and restarts the runner, or only watches a runner started by something else.")
            HStack {
                TextField("Binary path", text: binaryPath)
                Button("Detect") {
                    if let found = RunnerLocator.locate(model.config.runner) {
                        binaryPath.wrappedValue = found
                        model.status = "Found \(found)"
                    } else {
                        model.status = "No \(model.config.runner) binary found."
                    }
                }
                Button("Choose\u{2026}") { chooseBinary() }
            }
            .help("Path to the runner executable. Detect searches the usual install locations.")
            TextField("Host", text: $model.config.host)
                .help("Address the runner serves on. 127.0.0.1 keeps it on this machine.")
            TextField("Port", value: $model.config.port, format: .number.grouping(.never))
                .help("Port the runner serves on. Ollama's default is 11434.")
            HStack {
                Text("Environment")
                Spacer()
                Text(envSummary).foregroundStyle(.secondary)
                Button("Set Env\u{2026}") { showingEnvEditor = true }
            }
            .help("Extra environment variables set on a managed runner at launch, for example OLLAMA_LOAD_TIMEOUT. Click Set Env to add or remove variables.")
        }
    }

    private var inferenceHealthSection: some View {
        Section {
            Toggle("Check real inference, not only the API", isOn: deepProbeEnabled)
                .help("Periodically generate one token to catch a GPU or model hang even when the runner's lightweight API still answers.")
            if deepProbeEnabled.wrappedValue {
                if model.availableProbeModels.isEmpty {
                    TextField("Probe model", text: optional(\.probeModel),
                              prompt: Text("e.g. qwen2.5:0.5b"))
                } else {
                    Picker("Probe model", selection: optional(\.probeModel)) {
                        ForEach(probeModelOptions) { option in
                            Text(probeModelLabel(option)).tag(option.name)
                        }
                    }
                }
                HStack {
                    Button("Refresh Models") {
                        Task { await refreshProbeModels(selectSmallestWhenUnset: true) }
                    }
                    Button("Test Now") {
                        Task { await testProbe() }
                    }
                    .disabled(model.probeBusy || (model.config.probeModel ?? "").isEmpty)
                    if model.probeBusy { ProgressView().controlSize(.small) }
                }
                if !model.probeStatus.isEmpty {
                    Text(model.probeStatus).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Inference health")
        } footer: {
            Text("Opt in: the test loads the selected model and uses a small amount of GPU work. When sizes are available, the smallest installed model is listed first.")
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Local notifications", isOn: $model.config.localNotifications)
                .help("Show a macOS notification when the runner goes down or recovers.")
            TextField("ntfy topic (for phone alerts)", text: optional(\.ntfyTopic),
                      prompt: Text("e.g. hearth-alerts-7f3a (click here and type)"))
                .help("Subscribe to this topic in the ntfy app to get alerts on your phone. Leave blank to skip.")
            TextField("ntfy server", text: $model.config.ntfyServer)
                .help("ntfy server URL. The default is the public ntfy.sh.")
            TextField("Webhook URL", text: optional(\.webhookURL),
                      prompt: Text("https://your-server/hook (optional)"))
                .help("Hearth POSTs a small JSON status body here on each event, to wire into your own automation. Leave blank to skip.")
            TextField("Heartbeat URL", text: optional(\.heartbeatURL),
                      prompt: Text("Uptime Kuma push or healthchecks.io URL (optional)"))
                .help("While the runner is healthy, Hearth pings this URL on an interval; silence then means down, and the monitor you already run does the alerting.")
            number("Heartbeat interval", $model.config.heartbeatIntervalSeconds,
                   help: "Seconds between heartbeat pings while the runner is healthy. Match it to the monitor's expected period.")
            Toggle("Thermal alerts", isOn: $model.config.thermalAlerts)
                .help("Alert when the Mac's thermal state turns serious or critical, which throttles inference long before anything crashes.")
            numberInt("Memory alert percent", $model.config.memoryAlertPercent,
                      help: "Alert when system memory used reaches this percent, a precursor to the runner being killed under pressure. 0 disables it.")
            Toggle("Pause all notifications", isOn: $model.config.notificationsPaused)
                .help("Vacation mode: silence local, ntfy, and webhook alerts without clearing their settings. Events are still logged.")
            Toggle("Include runner log tail in alerts", isOn: $model.config.alertsIncludeLogTail)
                .help("Privacy trade-off, off by default: appends the runner's last log lines to down and failing alerts so the alert says why. Log lines are runner content (paths, model names, possibly request text) and travel to your notifiers, including the public ntfy.sh unless you self-host. hearth doctor warns about that combination.")
            Button("Send test notification") { sendTest() }
        }
    }

    private var controlSection: some View {
        Section {
            Toggle("Enable control endpoint", isOn: $model.config.controlEnabled)
                .help("Serve a small HTTP API so a phone can check status and start, stop, or restart the runner.")
                .onChange(of: model.config.controlEnabled) { _, enabled in
                    // The endpoint refuses to start without a token, so make one
                    // the moment it is enabled rather than failing silently.
                    if enabled, (model.config.controlToken ?? "").isEmpty {
                        model.config.controlToken = Self.randomToken()
                        model.status = "Generated a control token."
                    }
                }
            TextField("Bind host", text: $model.config.controlHost)
                .help("Address the control endpoint listens on. Use a private or Tailscale address.")
            TextField("Port", value: $model.config.controlPort, format: .number.grouping(.never))
                .help("Port for the control endpoint.")
            HStack {
                TextField("Bearer token", text: optional(\.controlToken),
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
            Button("Copy phone URL") { copyPhoneURL() }
            Toggle("Tokens-per-second metrics proxy", isOn: $model.config.metricsProxyEnabled)
                .help("Opt-in: a transparent relay in front of the runner that reads the throughput numbers generations already report, surfaced on the status page, hearth status, and /metrics. Point your clients at the proxy port instead of the runner port; hearth proxy-setup prints ready-made snippets.")
            numberInt("Metrics proxy port", $model.config.metricsProxyPort,
                      help: "Port the metrics proxy listens on. Clients use this port in place of the runner port while the proxy is enabled.")
        } header: {
            Text("Remote control")
        } footer: {
            Text("Serve this on a private network only (a Tailscale address is ideal), never the open internet.")
        }
    }

    private var loggingSection: some View {
        Section("Runner log") {
            TextField("Max bytes before rotating", value: $model.config.logMaxBytes, format: .number.grouping(.never))
                .help("Rotate the runner log once it grows past this many bytes.")
            TextField("Rotated files to keep", value: $model.config.logKeepFiles, format: .number.grouping(.never))
                .help("How many rotated log files to keep before deleting the oldest.")
        }
    }

    private var advancedSection: some View {
        Section {
            Text("The defaults here suit almost every setup; a normal install never needs to touch them.")
                .font(.callout).foregroundStyle(.secondary)
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
            Text("Advanced")
        } footer: {
            Text("For the headless root daemon, set Runner user and verify with hearth doctor-daemon.")
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
                    Task { await refreshProbeModels(selectSmallestWhenUnset: true) }
                } else {
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
    private func refreshProbeModels(selectSmallestWhenUnset: Bool) async {
        guard !model.probeBusy else { return }
        model.probeBusy = true
        defer { model.probeBusy = false }
        do {
            let models = try await RunnerProbeSetup.availableModels(config: model.config)
            model.availableProbeModels = models
            guard !models.isEmpty else {
                model.probeStatus = "No models were reported. Load or install a small model, then refresh."
                return
            }
            let current = (model.config.probeModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if selectSmallestWhenUnset && current.isEmpty, let smallest = models.first {
                model.config.probeModel = smallest.name
                model.probeStatus = "Selected \(smallest.name), the smallest model size the runner reported. Use Test Now to verify it."
            } else {
                model.probeStatus = "Found \(models.count) available model\(models.count == 1 ? "" : "s")."
            }
        } catch {
            model.availableProbeModels = []
            model.probeStatus = error.localizedDescription
        }
    }

    @MainActor
    private func testProbe() async {
        guard !model.probeBusy,
              let probeModel = model.config.probeModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !probeModel.isEmpty else { return }
        model.probeBusy = true
        model.probeStatus = "Running a one-token inference test\u{2026}"
        defer { model.probeBusy = false }
        do {
            let result = try await RunnerProbeSetup.test(config: model.config, model: probeModel)
            model.probeStatus = String(format: "Inference test passed in %.1f seconds. Save to enable ongoing checks.", result.elapsed)
        } catch {
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
