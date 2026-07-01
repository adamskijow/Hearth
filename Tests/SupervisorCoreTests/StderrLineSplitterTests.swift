// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct StderrLineSplitterTests {
    private func d(_ s: String) -> Data { Data(s.utf8) }

    @Test func splitsCompleteLines() {
        var s = StderrLineSplitter()
        #expect(s.ingest(d("a\nb\n")) == ["a", "b"])
    }

    @Test func holdsAPartialLineAcrossChunks() {
        var s = StderrLineSplitter()
        #expect(s.ingest(d("hel")) == [])
        #expect(s.ingest(d("lo\nworld")) == ["hello"])
        #expect(s.flush() == "world")
    }

    @Test func forceFlushesARunawayNoNewlineLine() {
        var s = StderrLineSplitter(maxPartialBytes: 8)
        #expect(s.ingest(d("0123456789")) == ["0123456789"])   // over the cap, no newline
        #expect(s.flush() == nil)                              // nothing left buffered
    }

    @Test func flushOnEmptyIsNil() {
        var s = StderrLineSplitter()
        #expect(s.flush() == nil)
    }
}
