// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct TailnetAddressTests {
    @Test func recognizesCarrierGradeNATRange() {
        #expect(TailnetAddress.isTailnetIPv4("100.64.0.1"))
        #expect(TailnetAddress.isTailnetIPv4("100.100.50.2"))
        #expect(TailnetAddress.isTailnetIPv4("100.127.255.255"))
    }

    @Test func rejectsAddressesOutsideTheRange() {
        #expect(!TailnetAddress.isTailnetIPv4("100.63.255.255")) // just below
        #expect(!TailnetAddress.isTailnetIPv4("100.128.0.0"))    // just above
        #expect(!TailnetAddress.isTailnetIPv4("192.168.1.10"))
        #expect(!TailnetAddress.isTailnetIPv4("10.0.0.1"))
        #expect(!TailnetAddress.isTailnetIPv4("127.0.0.1"))
    }

    @Test func rejectsMalformedInput() {
        #expect(!TailnetAddress.isTailnetIPv4("100.64.0"))
        #expect(!TailnetAddress.isTailnetIPv4("100.64.0.1.2"))
        #expect(!TailnetAddress.isTailnetIPv4("100.64.0.256"))
        #expect(!TailnetAddress.isTailnetIPv4("not-an-ip"))
        #expect(!TailnetAddress.isTailnetIPv4(""))
    }
}
