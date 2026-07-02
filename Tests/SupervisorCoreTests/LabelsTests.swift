// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

/// The short human labels that reach notifications and the menubar. Locked down
/// so the wording does not drift unnoticed.
struct LabelsTests {
    @Test func exitReasonLabels() {
        #expect(ExitReason.running.label == "running")
        #expect(ExitReason.cleanExit.label == "clean exit")
        #expect(ExitReason.crash(code: 1).label == "crashed (exit code 1)")
        #expect(ExitReason.outOfMemory.label == "ran out of memory")
        #expect(ExitReason.signal(9).label == "force-killed (signal 9, often the system reclaiming memory)")
        #expect(ExitReason.signal(15).label == "asked to stop by another process (signal 15)")
        #expect(ExitReason.signal(11).label == "crashed (signal 11)")
        #expect(ExitReason.unknown.label == "unknown exit")
    }

    @Test func downReasonLabels() {
        #expect(DownReason.wedged.label == "stuck (still running, but not answering)")
        // crashed delegates to the classified exit reason's label.
        #expect(DownReason.crashed(.outOfMemory).label == "ran out of memory")
        #expect(DownReason.crashed(.crash(code: 137)).label == "crashed (exit code 137)")
    }
}
