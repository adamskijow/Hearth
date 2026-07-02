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

/// EXPERIMENTAL: asks the hearth-reboot-helper root daemon to reboot instead of
/// doing it directly, so a non-root supervisor can keep the recovery ladder.
/// The helper enforces its own peer-uid check and rate limit; this client just
/// says "reboot" on the socket and reports what came back.
struct HelperSystemController: SystemControlling {
    let socketPath: String

    func reboot() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            warn("could not create a socket: errno \(errno)")
            return
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            warn("socket path too long: \(socketPath)")
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            warn("could not reach the reboot helper at \(socketPath) (errno \(errno)); is it installed? See docs/running-headless.md.")
            return
        }
        _ = "reboot\n".withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(fd, &buffer, buffer.count)
        let reply = count > 0
            ? String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if reply != "ok" {
            warn("the reboot helper declined (\(reply.isEmpty ? "no reply" : reply)); its log has the reason.")
        }
    }

    func bootedAt() -> Date? {
        SystemController().bootedAt()
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("Hearth: \(message)\n".utf8))
    }
}
