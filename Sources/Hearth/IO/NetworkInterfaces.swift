// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Read only inspection of the local network interfaces, used to find the
/// Tailscale tailnet address so the menubar can show the phone what URL to hit
/// for the control endpoint. It only reads interface addresses; it does not
/// configure or change anything.
enum NetworkInterfaces {
    static func tailnetIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if TailnetAddress.isTailnetIPv4(ip) {
                return ip
            }
        }
        return nil
    }
}
