// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Reboots the Mac for the last rung of the recovery ladder. This requires root,
/// so it only takes effect when Hearth runs as the headless LaunchDaemon; in any
/// other context the reboot command is rejected and logged.
struct SystemController: SystemControlling {
    func reboot() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
        task.arguments = ["-r", "now"]
        do {
            try task.run()
        } catch {
            FileHandle.standardError.write(Data(
                "Hearth: could not reboot (needs root, the headless daemon): \(error.localizedDescription)\n".utf8))
        }
    }
}
