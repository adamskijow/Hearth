// SPDX-License-Identifier: MIT
//
// hearth-reboot-helper: the one privileged action, isolated. EXPERIMENTAL.
//
// The root LaunchDaemon form of Hearth runs the whole supervisor as root only
// because the recovery ladder's last resort is a reboot. This helper inverts
// that: it is a tiny root daemon whose entire API is "reboot", offered on a
// root-owned unix socket that only one configured uid may use, rate limited in
// process. A non-root Hearth (with rebootViaHelper on) asks it instead of
// holding root itself.
//
// Defense in depth, three layers: the socket file is chowned to the allowed
// uid with mode 0600 (only that uid and root can connect at all), every
// connection's peer is re-verified via LOCAL_PEERCRED, and reboots are rate
// limited here regardless of what the client asks. The helper never reads more
// than one short line and never writes anything but "ok" or "denied".

import Foundation
import Darwin

func warn(_ message: String) {
    FileHandle.standardError.write(Data("hearth-reboot-helper: \(message)\n".utf8))
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, let allowedUID = UInt32(arguments[1]) else {
    warn("usage: hearth-reboot-helper <allowed-uid> [socket-path]")
    exit(2)
}
let socketPath = arguments.count >= 3 ? arguments[2] : "/var/run/hearth-reboot.sock"
guard geteuid() == 0 else {
    warn("must run as root (it exists to hold the reboot capability)")
    exit(1)
}
guard allowedUID != 0 else {
    warn("refusing an allowed-uid of root; the point is an unprivileged client")
    exit(2)
}

// Reboots at most this often, whatever the client asks. Mirrors the floor of
// Hearth's own rebootMinIntervalSeconds.
let minimumInterval: TimeInterval = 300
var lastRebootAt: Date?

unlink(socketPath)
let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard listenFD >= 0 else { warn("socket: errno \(errno)"); exit(1) }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    warn("socket path too long"); exit(2)
}
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    raw.copyBytes(from: pathBytes)
}
let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else { warn("bind \(socketPath): errno \(errno)"); exit(1) }
// Only the allowed uid (and root) can even connect; peer checks re-verify.
guard chmod(socketPath, 0o600) == 0, chown(socketPath, allowedUID, 0) == 0 else {
    warn("chmod/chown \(socketPath): errno \(errno)"); exit(1)
}
guard listen(listenFD, 4) == 0 else { warn("listen: errno \(errno)"); exit(1) }
warn("serving on \(socketPath) for uid \(allowedUID)")

/// The connected peer's effective uid, or nil if it cannot be read.
func peerUID(of fd: Int32) -> UInt32? {
    var credentials = xucred()
    var length = socklen_t(MemoryLayout<xucred>.size)
    // SOL_LOCAL (0) / LOCAL_PEERCRED (0x001), numerically: the constants are
    // not reliably surfaced to Swift across SDK versions.
    guard getsockopt(fd, 0, 0x001, &credentials, &length) == 0,
          credentials.cr_version == XUCRED_VERSION else { return nil }
    return credentials.cr_uid
}

func respond(_ fd: Int32, _ line: String) {
    _ = line.withCString { write(fd, $0, strlen($0)) }
}

while true {
    let client = accept(listenFD, nil, nil)
    guard client >= 0 else { continue }
    defer { close(client) }

    guard let uid = peerUID(of: client), uid == allowedUID else {
        warn("denied: peer uid \(peerUID(of: client).map(String.init) ?? "unreadable")")
        respond(client, "denied\n")
        continue
    }

    var buffer = [UInt8](repeating: 0, count: 64)
    let count = read(client, &buffer, buffer.count)
    guard count > 0 else { continue }
    let command = String(decoding: buffer[0..<count], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard command == "reboot" else {
        respond(client, "denied\n")
        continue
    }
    if let last = lastRebootAt, Date().timeIntervalSince(last) < minimumInterval {
        warn("denied: rate limited (last reboot \(Int(Date().timeIntervalSince(last)))s ago)")
        respond(client, "denied\n")
        continue
    }
    lastRebootAt = Date()
    warn("rebooting at the supervisor's request")
    respond(client, "ok\n")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
    task.arguments = ["-r", "now"]
    do {
        try task.run()
    } catch {
        warn("shutdown failed: \(error.localizedDescription)")
    }
}
