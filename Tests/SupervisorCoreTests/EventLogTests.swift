// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct EventLogTests {
    @Test func formatsALine() {
        #expect(EventLog.line(timestamp: "2026-06-28T12:00:00Z", message: "Down: wedged")
                == "2026-06-28T12:00:00Z  Down: wedged")
    }

    @Test func lastLinesReturnsTheTail() {
        let body = "a\nb\nc\nd\n"
        #expect(EventLog.lastLines(body, count: 2) == ["c", "d"])
        #expect(EventLog.lastLines(body, count: 10) == ["a", "b", "c", "d"])  // fewer than asked
        #expect(EventLog.lastLines(body, count: 0).isEmpty)
        #expect(EventLog.lastLines("", count: 5).isEmpty)
    }

    @Test func appendingTrimsToTheCap() {
        var body = ""
        for i in 1...5 { body = EventLog.appended(body, line: "line\(i)", maxLines: 3) }
        #expect(EventLog.lastLines(body, count: 10) == ["line3", "line4", "line5"])
        #expect(body.hasSuffix("\n"))
    }
}
