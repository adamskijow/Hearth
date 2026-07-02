// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Analytics over the event log: counts, recovery times, and cause histogram,
/// parsed from the same lines EventLog writes.
struct EventStatsTests {
    // Lines exactly as EventLogStore + StatusText.describe produce them.
    private let log = [
        "2026-07-01 09:00:00  Started",
        "2026-07-01 09:00:02  Became healthy",
        "2026-07-01 12:30:00  Down: stuck (still running, but not answering)",
        "2026-07-01 12:30:30  Restarted (attempt 1)",
        "2026-07-01 12:31:00  Recovered",
        "2026-07-02 03:00:00  Maintenance restart",
        "2026-07-02 18:00:00  Down: ran out of memory",
        "2026-07-02 18:05:00  Recovered",
        "2026-07-03 08:00:00  Down: ran out of memory",
        "2026-07-03 08:00:10  Failing: 5 failures within 60s",
    ]

    @Test func countsTransitions() {
        let s = EventStats.summarize(log)
        #expect(s.downCount == 3)
        #expect(s.recoveredCount == 2)
        #expect(s.crashLoopCount == 1)
        #expect(s.maintenanceRestarts == 1)
    }

    @Test func measuresRecoveryFromDownToRecovered() {
        let s = EventStats.summarize(log)
        // 30s from the first wedge, 300s from the OOM.
        #expect(s.recoveryTimes == [60, 300])
        #expect(s.meanRecovery == 180)
        #expect(s.longestRecovery == 300)
    }

    @Test func histogramsCausesMostFrequentFirst() {
        let s = EventStats.summarize(log)
        #expect(s.byReason.first?.reason == "ran out of memory")
        #expect(s.byReason.first?.count == 2)
        #expect(s.byReason.contains { $0.reason == "stuck (still running, but not answering)" })
    }

    @Test func reportsTheRetainedWindow() throws {
        let s = EventStats.summarize(log)
        let window = try #require(s.window)
        // First line to last line: two days and change.
        #expect(window.last.timeIntervalSince(window.first) > 86_400)
    }

    @Test func aBurstOfDownsBeforeOneRecoveryMeasuresFromTheFirst() {
        let burst = [
            "2026-07-01 10:00:00  Down: stuck (still running, but not answering)",
            "2026-07-01 10:00:30  Down: stuck (still running, but not answering)",
            "2026-07-01 10:02:00  Recovered",
        ]
        let s = EventStats.summarize(burst)
        #expect(s.downCount == 2)
        #expect(s.recoveryTimes == [120])   // from the first down, not the second
    }

    @Test func junkLinesAreSkippedNotCrashed() {
        let s = EventStats.summarize(["", "not a log line", "2026  malformed", "garbage  garbage"])
        #expect(s.downCount == 0)
        #expect(s.window == nil)
    }

    @Test func emptyLogSummarizesToNothing() {
        let s = EventStats.summarize([])
        #expect(s.window == nil)
        #expect(s.meanRecovery == nil)
    }
}
