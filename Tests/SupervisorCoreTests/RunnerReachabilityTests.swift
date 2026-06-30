// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerReachabilityTests {
    @Test func loopbackHostsAreLocalOnly() {
        for host in ["127.0.0.1", "localhost", "::1", "LocalHost", " 127.0.0.1 "] {
            #expect(RunnerReachability.isLoopbackOnly(host: host), "\(host) should be loopback-only")
        }
        for host in ["0.0.0.0", "192.168.1.5", "100.64.0.2", "my-mac.local"] {
            #expect(!RunnerReachability.isLoopbackOnly(host: host), "\(host) should not be loopback-only")
        }
    }

    @Test func loopbackHasNoReachableURL() {
        for host in ["127.0.0.1", "localhost", "::1", ""] {
            #expect(RunnerReachability.url(host: host, port: 11434, resolvedAddress: "192.168.1.5") == nil,
                    "\(host) should not advertise a reachable URL")
        }
    }

    @Test func wildcardUsesTheResolvedAddress() {
        // Bound to all interfaces: advertise the address another machine would dial.
        #expect(RunnerReachability.url(host: "0.0.0.0", port: 11434, resolvedAddress: "192.168.1.5")
                == "http://192.168.1.5:11434")
        // No address to advertise yet: no URL rather than a useless one.
        #expect(RunnerReachability.url(host: "0.0.0.0", port: 11434, resolvedAddress: nil) == nil)
        #expect(RunnerReachability.url(host: "0.0.0.0", port: 11434, resolvedAddress: "") == nil)
    }

    @Test func explicitRoutableHostIsTheAddress() {
        // An explicit LAN or tailnet host is itself the dialable address; the
        // resolved address is irrelevant.
        #expect(RunnerReachability.url(host: "192.168.1.50", port: 11434, resolvedAddress: nil)
                == "http://192.168.1.50:11434")
        #expect(RunnerReachability.url(host: "100.100.20.3", port: 8080, resolvedAddress: "10.0.0.9")
                == "http://100.100.20.3:8080")
    }

    @Test func privateRangesAreRecognized() {
        for ip in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.4.4", "192.168.0.1", "192.168.68.50"] {
            #expect(PrivateIPv4.isPrivate(ip), "\(ip) is private")
        }
    }

    @Test func nonPrivateAndMalformedAreRejected() {
        // Public, link-local, tailnet (CGNAT, not RFC 1918), loopback, and junk.
        for ip in ["8.8.8.8", "169.254.1.1", "172.15.0.1", "172.32.0.1",
                   "100.64.0.2", "127.0.0.1", "192.169.0.1", "not.an.ip", "10.0.0", "256.0.0.1", ""] {
            #expect(!PrivateIPv4.isPrivate(ip), "\(ip) is not a private LAN address")
        }
    }
}
