// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import SupervisorCore

/// The one-time first-run welcome window. A menubar app with no Dock icon and no
/// window is easy to launch and then lose ("did it even start?"), so on the first
/// run Hearth shows this once: it points at the menubar, confirms what it found,
/// makes the missing-runner case actionable, and asks for notification permission
/// with context rather than a cold prompt at launch. Native and system-appearance
/// aware, like the menu and Preferences.
@MainActor
final class WelcomeController: NSObject, NSWindowDelegate {
    static let shownKey = "hearthWelcomeShown"
    private var window: NSWindow?

    func show(runner: String,
              foundPath: String?,
              installHint: String,
              collisionWarning: String?,
              onSwitchToAttached: @escaping () -> Void,
              onEnableNotifications: @escaping () -> Void,
              onOpenPreferences: @escaping () -> Void) {
        let view = WelcomeView(
            runner: runner,
            foundPath: foundPath,
            installHint: installHint,
            collisionWarning: collisionWarning,
            onSwitchToAttached: { [weak self] in self?.window?.close(); onSwitchToAttached() },
            onEnableNotifications: onEnableNotifications,
            onOpenPreferences: { [weak self] in self?.window?.close(); onOpenPreferences() },
            onDone: { [weak self] in self?.window?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Hearth"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        self.window = window

        // Become a regular app while the window is open so it can take focus, then
        // drop back to an accessory (no Dock icon) when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: Self.shownKey)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }
}

struct WelcomeView: View {
    let runner: String
    let foundPath: String?
    let installHint: String
    let collisionWarning: String?
    let onSwitchToAttached: () -> Void
    let onEnableNotifications: () -> Void
    let onOpenPreferences: () -> Void
    let onDone: () -> Void

    @State private var notificationsEnabled = false

    private var runnerLabel: String {
        RunnerKind(fromConfigString: runner).displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hearth is running")
                        .font(.title2).fontWeight(.semibold)
                    Label("It lives in your menu bar, look for the flame.", systemImage: "arrow.up")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            statusBlock

            if let collisionWarning {
                collisionBlock(collisionWarning)
            } else if foundPath != nil {
                Label("Your apps need no changes: they keep talking to the runner as they do now, and Hearth keeps it alive. Several apps and models can share the one runner.", systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Label("Get alerted when the runner goes down.", systemImage: "bell")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(notificationsEnabled ? "Notifications on" : "Enable notifications") {
                    onEnableNotifications()
                    notificationsEnabled = true
                }
                .disabled(notificationsEnabled)
            }

            Label("If anything ever looks off, run `hearth doctor` in Terminal for a full checkup.",
                  systemImage: "stethoscope")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button("Open Preferences", action: onOpenPreferences)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder private var statusBlock: some View {
        HStack(alignment: .top, spacing: 11) {
            if let found = foundPath {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Supervising \(runnerLabel)").fontWeight(.medium)
                    Text("Found at \(found). Keeping it alive and serving.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow).font(.title3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(runnerLabel) not found").fontWeight(.medium)
                    Text("Install it, then reopen Hearth (or set the path in Preferences).")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(installHint)
                            .font(.system(.callout, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(installHint, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func collisionBlock(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(runnerLabel) is already running").fontWeight(.medium)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Watch the existing runner instead", action: onSwitchToAttached)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
