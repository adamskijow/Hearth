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
    }

    // MARK: Sections

    private var runnerSection: some View {
        Section("Runner") {
            Picker("Runner", selection: $model.config.runner) {
                Text("Ollama").tag("ollama")
                Text("LM Studio").tag("lmstudio")
                Text("mlx_lm").tag("mlx")
            }
            Picker("Mode", selection: $model.config.mode) {
                Text("Managed (Hearth launches it)").tag("managed")
                Text("Attached (monitor only)").tag("attached")
            }
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
            TextField("Host", text: $model.config.host)
            TextField("Port", value: $model.config.port, format: .number.grouping(.never))
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Local notifications", isOn: $model.config.localNotifications)
            TextField("ntfy topic (for phone alerts)", text: optional(\.ntfyTopic))
            TextField("ntfy server", text: $model.config.ntfyServer)
            Button("Send test notification") { sendTest() }
        }
    }

    private var controlSection: some View {
        Section("Remote control") {
            Toggle("Enable control endpoint", isOn: $model.config.controlEnabled)
            TextField("Bind host", text: $model.config.controlHost)
            TextField("Port", value: $model.config.controlPort, format: .number.grouping(.never))
            HStack {
                TextField("Bearer token", text: optional(\.controlToken))
                Button("Generate") { model.config.controlToken = Self.randomToken() }
            }
            Button("Copy phone URL") { copyPhoneURL() }
        }
    }

    private var loggingSection: some View {
        Section("Runner log") {
            TextField("Max bytes before rotating", value: $model.config.logMaxBytes, format: .number.grouping(.never))
            TextField("Rotated files to keep", value: $model.config.logKeepFiles, format: .number.grouping(.never))
        }
    }

    private var advancedSection: some View {
        Section("Advanced (timing, seconds)") {
            number("Probe interval", $model.config.probeIntervalSeconds)
            number("Probe timeout", $model.config.probeTimeoutSeconds)
            number("Startup grace", $model.config.startupGraceSeconds)
            number("Initial backoff", $model.config.initialBackoffSeconds)
            number("Backoff multiplier", $model.config.backoffMultiplier)
            number("Max backoff", $model.config.maxBackoffSeconds)
            HStack {
                Text("Crash loop threshold")
                Spacer()
                TextField("", value: $model.config.crashLoopThreshold, format: .number.grouping(.never))
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            number("Crash loop window", $model.config.crashLoopWindowSeconds)
            number("Failing retry interval", $model.config.failingProbeIntervalSeconds)
        }
    }

    private func number(_ label: String, _ binding: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: binding, format: .number).frame(width: 90).multilineTextAlignment(.trailing)
        }
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
        LocalNotifier.post(title: "Hearth test", body: "This is a test notification.")
        if let topic = model.config.ntfyTopic, !topic.isEmpty {
            let notifier = NtfyNotifier(server: model.config.ntfyServer, topic: topic)
            Task {
                await notifier.notify(HearthNotification(level: .info, title: "Hearth test", body: "ntfy is working.", event: .becameHealthy))
            }
            model.status = "Sent local and ntfy test notifications."
        } else {
            model.status = "Sent a local test notification."
        }
    }

    private func copyPhoneURL() {
        let host = NetworkInterfaces.tailnetIPv4() ?? model.config.controlHost
        let url = "http://\(host):\(model.config.controlPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        model.status = "Copied \(url)"
    }

    private static func randomToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
