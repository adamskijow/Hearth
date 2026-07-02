// SPDX-License-Identifier: MIT

import Foundation

/// The Hearth supervision layers installed on this Mac, and who actually holds
/// the single-instance lock. Layers accumulate silently over time (a root
/// LaunchDaemon from an old install, a user LaunchAgent, the menubar login
/// item); the lock makes the extras harmless hot standbys, but nothing ever
/// said so, and a machine can end up with three stacked supervisors nobody
/// remembers installing. Doctor gathers the facts (file existence, lock pid);
/// this decides what they mean, so the wording and the multi-layer warning are
/// testable without a filesystem.
public struct SupervisionLayers: Sendable, Equatable {
    public var rootDaemonInstalled: Bool
    public var userAgentInstalled: Bool
    /// nil when it cannot be determined (the CLI outside the app bundle).
    public var loginItemEnabled: Bool?
    public var lockHolderPID: Int?
    public var lockHolderAlive: Bool

    public init(rootDaemonInstalled: Bool,
                userAgentInstalled: Bool,
                loginItemEnabled: Bool?,
                lockHolderPID: Int?,
                lockHolderAlive: Bool) {
        self.rootDaemonInstalled = rootDaemonInstalled
        self.userAgentInstalled = userAgentInstalled
        self.loginItemEnabled = loginItemEnabled
        self.lockHolderPID = lockHolderPID
        self.lockHolderAlive = lockHolderAlive
    }

    /// The informational lines and any warnings for doctor to print.
    public func report() -> (lines: [String], diagnostics: [Diagnostic]) {
        var installed: [String] = []
        if rootDaemonInstalled { installed.append("root daemon (com.hearth.daemon)") }
        if userAgentInstalled { installed.append("login agent (com.hearth.headless)") }
        if loginItemEnabled == true { installed.append("menubar login item") }

        var lines: [String] = []
        switch installed.count {
        case 0:
            lines.append("no start-at-login supervision layer is installed; Hearth runs only when started by hand")
        case 1:
            lines.append("supervision layer: \(installed[0])")
        default:
            lines.append("supervision layers installed: \(installed.joined(separator: ", "))")
        }
        if loginItemEnabled == nil {
            lines.append("menubar login item: could not be checked from this context")
        }
        if let pid = lockHolderPID {
            lines.append(lockHolderAlive
                ? "supervising instance: pid \(pid) holds the lock"
                : "the last lock holder (pid \(pid)) is gone; the next Hearth to start takes over")
        } else {
            lines.append("no instance holds the single-instance lock right now")
        }

        var diagnostics: [Diagnostic] = []
        if installed.count > 1 {
            var removals: [String] = []
            if rootDaemonInstalled {
                removals.append("remove the root daemon with `sudo launchctl bootout system/com.hearth.daemon && sudo rm /Library/LaunchDaemons/com.hearth.daemon.plist`")
            }
            if userAgentInstalled {
                removals.append("remove the login agent with `hearth uninstall-agent`")
            }
            if loginItemEnabled == true {
                removals.append("turn off the login item in the menubar app's preferences")
            }
            diagnostics.append(Diagnostic(.warning,
                "\(installed.count) supervision layers are installed (\(installed.joined(separator: ", "))). The single-instance lock keeps the extras as hot standbys, so nothing breaks, but only one is doing the work and the rest are leftovers to remove. Keep one: \(removals.joined(separator: "; ")).") )
        }
        return (lines, diagnostics)
    }
}
