// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct ProcessExitDecodeTests {
    @Test func decodesACleanExit() {
        let e = ProcessExit.from(waitpidStatus: 0)   // exit 0: low 7 bits zero
        #expect(e.code == 0)
        #expect(!e.wasSignaled)
        #expect(e.signal == nil)
    }

    @Test func decodesANonZeroExit() {
        let e = ProcessExit.from(waitpidStatus: 3 << 8)   // exit code 3 lives in bits 8-15
        #expect(e.code == 3)
        #expect(!e.wasSignaled)
    }

    @Test func decodesASignalDeath() {
        let e = ProcessExit.from(waitpidStatus: 9)   // killed by SIGKILL: low 7 bits = signal
        #expect(e.wasSignaled)
        #expect(e.signal == 9)
        #expect(e.code == 0)
    }
}
