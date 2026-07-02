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
            baseline = new
            return
        }
        if new == model.config {
            baseline = new
            return
        }
        if model.config == baseline {
            model.config = new
            baseline = new
            model.status = "Config changed outside this window; now showing the new values."
        } else {
            model.status = "Config changed outside this window while you were editing; Save will overwrite that change."
        }
    }

    func show(config: HearthConfig) {
        model.config = config
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
}

@MainActor
final class PreferencesModel: ObservableObject {
    @Published var config: HearthConfig
    @Published var status: String = ""
    init(_ config: HearthConfig) { self.config = config }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let onSave: (HearthConfig) -> Void
    let onClose: () -> Void
    @State private var showingEnvEditor = false
    @State private var showAdvancedTuning = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                runnerSection
                notificationsSection
                controlSection
                loggingSection
                advancedSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(model.status).foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Close", action: onClose)
                Button("Save") { onSave(model.config); model.status = "Saved and reloaded." }
                    .keyboardShortcut(.defaultAction)
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
    }

    /// A short summary of the configured runner environment for the Preferences row.
    private var envSummary: String {
        let count = model.config.runnerEnv.count
        return count == 0 ? "None" : "\(count) variable\(count == 1 ? "" : "s")"
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
            Toggle("Pause all notifications", isOn: $model.config.notificationsPaused)
                .help("Vacation mode: silence local, ntfy, and webhook alerts without clearing their settings. Events are still logged.")
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
            Button("Copy phone URL") { copyPhoneURL() }
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
                TextField("Deep probe model", text: optional(\.probeModel),
                          prompt: Text("optional, e.g. qwen2.5:0.5b"))
                    .help("Optional: periodically generate one token with this model (pick a small one you have pulled) to catch a runner whose API answers while the model itself is stuck.")
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
            Text("Deep probes are optional. For the headless root daemon, set Runner user and verify with hearth doctor-daemon.")
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

    private static func randomToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
