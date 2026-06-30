// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Read only inspection of the local network interfaces, used to find the address
/// another device would dial: the Tailscale tailnet address for phone control, or
/// a private LAN address for the runner's "reachable at" line and `hearth doctor`.
/// It only reads interface addresses; it does not configure or change anything.
enum NetworkInterfaces {
    /// Every IPv4 address on the host's interfaces, in interface order.
    static func allIPv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [String] = []
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
            addresses.append(host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        return addresses
    }

    /// The Tailscale tailnet address, if this Mac is on a tailnet.
    static func tailnetIPv4() -> String? {
        allIPv4().first(where: TailnetAddress.isTailnetIPv4)
    }

    /// A private (RFC 1918) LAN address another computer on the same network would
    /// use to reach this Mac, or nil when there is no such interface.
    static func lanIPv4() -> String? {
        allIPv4().first(where: PrivateIPv4.isPrivate)
    }
}
