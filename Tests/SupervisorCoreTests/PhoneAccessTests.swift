// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct PhoneAccessTests {
    @Test func prefersTheTailnetAddress() {
        // With a tailnet address, that is the phone-reachable host, even if the
        // control host is bound to loopback.
        #expect(PhoneAccess.url(tailnetIPv4: "100.64.0.5", controlHost: "127.0.0.1", controlPort: 11435)
                == "http://100.64.0.5:11435")
    }

    @Test func loopbackOnlyIsNotAdvertised() {
        // A phone cannot reach loopback or the 0.0.0.0 wildcard, so no URL is shown
        // rather than a misleading one.
        for host in ["127.0.0.1", "localhost", "::1", "0.0.0.0", ""] {
            #expect(PhoneAccess.url(tailnetIPv4: nil, controlHost: host, controlPort: 11435) == nil,
                    "\(host) should not be advertised as phone access")
        }
    }

    @Test func anExplicitNonLoopbackHostIsUsed() {
        // If the user bound the control endpoint to a specific reachable address,
        // show that even without a detected tailnet address.
        #expect(PhoneAccess.url(tailnetIPv4: nil, controlHost: "192.168.1.50", controlPort: 11435)
                == "http://192.168.1.50:11435")
        #expect(PhoneAccess.url(tailnetIPv4: nil, controlHost: "100.100.20.3", controlPort: 9000)
                == "http://100.100.20.3:9000")
    }
}
