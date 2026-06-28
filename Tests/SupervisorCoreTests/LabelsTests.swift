// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

/// The short human labels that reach notifications and the menubar. Locked down
/// so the wording does not drift unnoticed.
struct LabelsTests {
    @Test func exitReasonLabels() {
        #expect(ExitReason.running.label == "running")
        #expect(ExitReason.cleanExit.label == "clean exit")
        #expect(ExitReason.crash(code: 1).label == "crash (code 1)")
        #expect(ExitReason.outOfMemory.label == "out of memory")
        #expect(ExitReason.signal(9).label == "killed by signal 9")
        #expect(ExitReason.unknown.label == "unknown exit")
    }

    @Test func downReasonLabels() {
        #expect(DownReason.wedged.label == "wedged (alive but not answering)")
        // crashed delegates to the classified exit reason's label.
        #expect(DownReason.crashed(.outOfMemory).label == "out of memory")
        #expect(DownReason.crashed(.crash(code: 137)).label == "crash (code 137)")
    }
}
