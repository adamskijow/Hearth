// SPDX-License-Identifier: MIT

import Foundation

/// Whether the runner is reachable from other machines, derived purely from its
/// configured bind host. Mirrors `PhoneAccess`, but for the runner's own endpoint
/// rather than the control one: the menu shows a "reachable at" URL when the
/// runner is bound to a routable address, and `hearth doctor` explains the
/// loopback-only default and how to open it up. The interface scan that supplies a
/// concrete LAN or tailnet address lives in the app; the classification is here so
/// it can be tested without a network.
public enum RunnerReachability {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "::ffff:127.0.0.1"]
    private static let wildcardHosts: Set<String> = ["0.0.0.0", "::", "*"]

    /// True when the runner is bound only to loopback, so nothing off this machine
    /// can reach it. This is the default and is correct for single-machine use; it
    /// is a problem only when you want another computer to connect.
    public static func isLoopbackOnly(host: String) -> Bool {
        loopbackHosts.contains(normalized(host))
    }

    /// A dialable http URL another machine would use to reach the runner, or nil
    /// when it is loopback-only or bound to the wildcard with no known address to
    /// advertise. For an explicit routable host the host is the address; for the
    /// wildcard the resolved LAN or tailnet address (if any) stands in.
    public static func url(host: String, port: Int, resolvedAddress: String?) -> String? {
        let trimmed = normalized(host)
        if trimmed.isEmpty || isLoopbackOnly(host: trimmed) { return nil }
        let address: String
        if wildcardHosts.contains(trimmed) {
            guard let resolvedAddress, !resolvedAddress.isEmpty else { return nil }
            address = resolvedAddress
        } else {
            address = host.trimmingCharacters(in: .whitespaces)
        }
        return "http://\(address):\(port)"
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// Recognizing a private (RFC 1918) LAN IPv4, so the app can pick the address
/// another computer on the same network would dial to reach this Mac. Pure and
/// testable; the interface scan that feeds it lives in the app. The Tailscale
/// range (100.64.0.0/10) is carrier-grade NAT, not RFC 1918, so it is handled
/// separately by `TailnetAddress`.
public enum PrivateIPv4 {
    public static func isPrivate(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4 else { return false }
        let v = octets.compactMap { $0 }
        guard v.count == 4, v.allSatisfy({ (0...255).contains($0) }) else { return false }
        if v[0] == 10 { return true }                               // 10.0.0.0/8
        if v[0] == 172, (16...31).contains(v[1]) { return true }    // 172.16.0.0/12
        if v[0] == 192, v[1] == 168 { return true }                 // 192.168.0.0/16
        return false
    }
}
