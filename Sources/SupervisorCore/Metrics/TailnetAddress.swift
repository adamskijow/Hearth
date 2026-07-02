// SPDX-License-Identifier: MIT

import Foundation

/// Recognizing a Tailscale tailnet address. Tailscale assigns IPv4 addresses
/// from the carrier grade NAT range 100.64.0.0/10, so an interface address in
/// that range is almost certainly the tailnet one. Pure and testable; the
/// interface scan that feeds it lives in the app.
public enum TailnetAddress {
    public static func isTailnetIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) }
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { $0 }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return false }
        // 100.64.0.0/10 spans 100.64.0.0 through 100.127.255.255.
        return values[0] == 100 && (64...127).contains(values[1])
    }
}

/// The control URL a phone could actually reach. Prefers the tailnet address;
/// otherwise uses an explicit non-loopback control host. Returns nil when only a
/// loopback or the 0.0.0.0 wildcard is available, since neither is dialable from a
/// phone, so the menu does not advertise a "phone access" URL that cannot work.
public enum PhoneAccess {
    private static let unreachableHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "0.0.0.0", ""]

    public static func url(tailnetIPv4: String?, controlHost: String, controlPort: Int) -> String? {
        let host: String
        if let tailnetIPv4 {
            host = tailnetIPv4
        } else if unreachableHosts.contains(controlHost) {
            return nil
        } else {
            host = controlHost
        }
        // Bracket an IPv6 literal so the advertised URL (menu, QR code, Copy
        // phone URL) is actually openable on the phone.
        return "http://\(urlAuthorityHost(for: host)):\(controlPort)"
    }
}
