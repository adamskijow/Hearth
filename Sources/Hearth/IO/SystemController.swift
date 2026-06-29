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

    /// The kernel's boot time from `kern.boottime`. Needs no root, and unlike the
    /// reboot history file it cannot be lost across a reboot, so it backstops the
    /// reboot loop guard.
    func bootedAt() -> Date? {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctl(&mib, UInt32(mib.count), &boot, &size, nil, 0)
        guard result == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}
