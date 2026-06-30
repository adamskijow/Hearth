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

    init(config: HearthConfig, onSave: @escaping (HearthConfig) -> Void) {
        self.model = PreferencesModel(config)
        self.onSave = onSave
        super.init()
    }

    func show(config: HearthConfig) {
        model.config = config
        if window == nil {
            let view = PreferencesView(
                model: model,
                onSave: { [weak self] in self?.onSave($0) },
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
            }
            .help("Which local LLM server Hearth supervises.")
            Picker("Mode", selection: $model.config.mode) {
                Text("Managed (Hearth launches it)").tag("managed")
                Text("Attached (monitor only)").tag("attached")
            }
            .help("Managed: Hearth starts and restarts the runner. Attached: Hearth only watches a runner you start yourself.")
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
            number("Probe interval", $model.config.probeIntervalSeconds,
                   help: "How often to check the runner's health while it is up.")
            number("Probe timeout", $model.config.probeTimeoutSeconds,
                   help: "How long a health probe waits before it counts as a failure.")
            number("Startup grace", $model.config.startupGraceSeconds,
                   help: "How long to allow for the runner to come up before treating it as failed.")
            number("Initial backoff", $model.config.initialBackoffSeconds,
                   help: "Wait before the first restart attempt.")
            number("Backoff multiplier", $model.config.backoffMultiplier,
                   help: "Each failed restart multiplies the wait by this.")
            number("Max backoff", $model.config.maxBackoffSeconds,
                   help: "Upper limit on the wait between restarts.")
            numberInt("Crash loop threshold", $model.config.crashLoopThreshold,
                      help: "Restarts within the window that trip the crash-loop brake.")
            number("Crash loop window", $model.config.crashLoopWindowSeconds,
                   help: "Time window for counting restarts toward the crash-loop brake.")
            number("Failing retry interval", $model.config.failingProbeIntervalSeconds,
                   help: "How often to retry while in the crash-loop (failing) state.")
        } header: {
            Text("Advanced (timing, seconds)")
        } footer: {
            Text("The defaults suit most setups. Lower the probe interval to notice failures sooner.")
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
            get: {
                switch model.config.runner.lowercased() {
                case "lmstudio", "lm-studio", "lm_studio": return model.config.lmStudioBinaryPath
                case "mlx", "mlx_lm", "mlx-lm": return model.config.mlxBinaryPath
                default: return model.config.ollamaBinaryPath
                }
            },
            set: { value in
                switch model.config.runner.lowercased() {
                case "lmstudio", "lm-studio", "lm_studio": model.config.lmStudioBinaryPath = value
                case "mlx", "mlx_lm", "mlx-lm": model.config.mlxBinaryPath = value
                default: model.config.ollamaBinaryPath = value
                }
            }
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
            controlHost: model.config.controlHost,
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
