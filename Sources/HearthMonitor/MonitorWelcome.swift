// SPDX-License-Identifier: MIT

import AppKit
import HearthMonitorCore
import SwiftUI

@MainActor
final class MonitorWelcomeController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onContinue: (Bool) throws -> Void
    private let onAddRunner: () -> Void
    private let appleAvailability: AppleModelAvailability

    init(appleAvailability: AppleModelAvailability,
         onContinue: @escaping (Bool) throws -> Void,
         onAddRunner: @escaping () -> Void) {
        self.appleAvailability = appleAvailability
        self.onContinue = onContinue
        self.onAddRunner = onAddRunner
        super.init()
    }

    func show() {
        if window == nil {
            let size = MonitorWelcomeView.windowSize(for: appleAvailability)
            let view = MonitorWelcomeView(
                appleAvailability: appleAvailability,
                onContinue: { [weak self] functional in
                    guard let self else { return nil }
                    do {
                        try self.onContinue(functional)
                        self.window?.close()
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                },
                onAddRunner: { [weak self] functional in
                    guard let self else { return nil }
                    do {
                        try self.onContinue(functional)
                        self.window?.close()
                        self.onAddRunner()
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                })
                .frame(width: size.width, height: size.height)
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Hearth Monitor"
            window.styleMask = [.titled, .closable]
            window.setContentSize(size)
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
}

struct MonitorWelcomeView: View {
    let appleAvailability: AppleModelAvailability
    let onContinue: (Bool) -> String?
    let onAddRunner: (Bool) -> String?
    @State private var functionalChecks: Bool
    @State private var errorMessage: String?

    init(appleAvailability: AppleModelAvailability = .available,
         onContinue: @escaping (Bool) -> String?,
         onAddRunner: @escaping (Bool) -> String?) {
        self.appleAvailability = appleAvailability
        self.onContinue = onContinue
        self.onAddRunner = onAddRunner
        _functionalChecks = State(initialValue: appleAvailability == .available)
    }

    static func windowSize(for availability: AppleModelAvailability) -> NSSize {
        let height: CGFloat = availability == .available ? 550 : 560
        return NSSize(width: 640, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Know when local AI is actually working")
                    .font(.largeTitle.weight(.semibold))
                Text("Hearth Monitor watches two complementary layers on your Mac. Both stay private, and neither requires a Hearth account.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 14) {
                modeCard(
                    icon: "brain.head.profile",
                    title: "Apple On-Device Model",
                    text: "On compatible Macs, verify availability and a real language-model response through Apple's public Foundation Models framework.")
                modeCard(
                    icon: "server.rack",
                    title: "Local AI Runners",
                    text: "Attach to Ollama, LM Studio, MLX, or Osaurus. Optional inference checks catch a runner whose API answers while generation is wedged.")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let availabilityMessage {
                        Label(availabilityMessage, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Run private on-device model functional checks", isOn: $functionalChecks)
                        .disabled(!canSelectFunctionalChecks)
                        .accessibilityLabel("Run private on-device model functional checks")
                    Text(functionalHelp)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Two failed checks are required before an incident or alert.",
                          systemImage: "checkmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(7)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
            HStack {
                Text("You can change either mode later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start and Add a Runner…") {
                    errorMessage = onAddRunner(functionalChecks)
                }
                .accessibilityLabel("Start and add a runner")
                Button("Start Monitoring") {
                    errorMessage = onContinue(functionalChecks)
                }
                .accessibilityLabel("Start monitoring")
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
    }

    private func modeCard(icon: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var canSelectFunctionalChecks: Bool {
        switch appleAvailability {
        case .available, .unavailable(.appleIntelligenceNotEnabled), .unavailable(.modelNotReady):
            return true
        case .unavailable:
            return false
        }
    }

    private var availabilityMessage: String? {
        switch appleAvailability {
        case .available: return nil
        case .unavailable(.unsupportedOS):
            return "Apple's on-device language model requires macOS 26. Local AI Runner monitoring is fully available."
        case .unavailable(.deviceNotEligible):
            return "This Mac is not eligible for Apple Intelligence. Local AI Runner monitoring is fully available."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is currently off. You can prepare checks now and enable it later in System Settings."
        case .unavailable(.modelNotReady):
            return "The Apple model is still downloading or preparing. Hearth can begin checking when macOS reports it ready."
        case .unavailable(.unsupportedLocale):
            return "Apple's system model does not support the current language or locale. Local AI Runner monitoring remains available."
        case .unavailable(.frameworkUnavailable):
            return "The Foundation Models framework is unavailable. Local AI Runner monitoring remains available."
        }
    }

    private var functionalHelp: String {
        guard canSelectFunctionalChecks else {
            return "Functional checks stay off on this Mac. Runner monitoring, shared incident history, and alerts still work."
        }
        if appleAvailability == .available {
            return "Recommended. Every 15 minutes, Hearth requests one tiny fixed response. The prompt and response are not saved. Checks pause for sleep, Low Power Mode, and serious thermal pressure."
        }
        return "Optional. If enabled, Hearth begins the tiny private check when macOS reports that Apple Intelligence is ready."
    }
}
