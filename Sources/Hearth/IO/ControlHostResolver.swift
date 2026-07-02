// SPDX-License-Identifier: MIT

import Foundation

/// Resolves the `controlHost` sentinel `"tailscale"` to whatever this Mac's
/// tailnet IPv4 is right now, at bind time, so a control endpoint meant for the
/// tailnet does not need a hand-copied address that goes stale when the tailnet
/// re-addresses. Fails closed: with no Tailscale interface present the endpoint
/// binds loopback, never the open network.
enum ControlHostResolver {
    static func resolve(_ configured: String) -> String {
        guard configured.trimmingCharacters(in: .whitespaces).lowercased() == "tailscale" else {
            return configured
        }
        if let tailnet = NetworkInterfaces.tailnetIPv4() {
            return tailnet
        }
        FileHandle.standardError.write(Data(
            "Hearth: controlHost is \"tailscale\" but no Tailscale interface was found; binding the control endpoint to 127.0.0.1 instead.\n".utf8))
        return "127.0.0.1"
    }
}
