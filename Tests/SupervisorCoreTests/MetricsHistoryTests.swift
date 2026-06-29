// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct MetricsHistoryTests {
    private func sample(_ secondsFromZero: TimeInterval, _ memory: Int?, thermal: String = "nominal", rss: Int64? = nil) -> MetricsSample {
        MetricsSample(at: Date(timeIntervalSince1970: secondsFromZero), memoryPercent: memory, thermal: thermal, runnerResidentBytes: rss)
    }

    @Test func recordingCapsAndDropsTooCloseSamples() {
        var history = MetricsHistory()
        history = history.recording(sample(0, 50), minInterval: 60)
        // Too soon (30s < 60s): dropped.
        history = history.recording(sample(30, 60), minInterval: 60)
        #expect(history.samples.count == 1)
        // Far enough: kept.
        history = history.recording(sample(60, 60), minInterval: 60)
        #expect(history.samples.count == 2)
    }

    @Test func recordingEvictsOldestBeyondCap() {
        var history = MetricsHistory()
        for i in 0..<10 {
            history = history.recording(sample(Double(i) * 60, 40 + i), cap: 5, minInterval: 60)
        }
        #expect(history.samples.count == 5)
        // Oldest dropped: the first kept sample is the 6th recorded one.
        #expect(history.samples.first?.memoryPercent == 45)
        #expect(history.samples.last?.memoryPercent == 49)
    }

    @Test func summaryComputesPeakAverageAndCurrent() {
        let history = MetricsHistory(samples: [sample(0, 40, rss: 100), sample(60, 80, rss: 300), sample(120, 60, rss: 200)])
        let summary = try! #require(history.summary())
        #expect(summary.count == 3)
        #expect(summary.peakMemoryPercent == 80)
        #expect(summary.averageMemoryPercent == 60)
        #expect(summary.currentMemoryPercent == 60)
        #expect(summary.peakRunnerResidentBytes == 300)
    }

    @Test func summaryDetectsAClimbingTrend() {
        // Memory steadily rising: classic creep a maintenance restart clears.
        let rising = MetricsHistory(samples: (0..<8).map { sample(Double($0) * 60, 40 + $0 * 3) })
        #expect(try! #require(rising.summary()).memoryTrend == .rising)

        let flat = MetricsHistory(samples: (0..<8).map { sample(Double($0) * 60, 55) })
        #expect(try! #require(flat.summary()).memoryTrend == .flat)

        let falling = MetricsHistory(samples: (0..<8).map { sample(Double($0) * 60, 80 - $0 * 3) })
        #expect(try! #require(falling.summary()).memoryTrend == .falling)
    }

    @Test func summaryCountsThermalTimeInState() {
        let history = MetricsHistory(samples: [
            sample(0, 40, thermal: "nominal"), sample(60, 40, thermal: "nominal"), sample(120, 40, thermal: "serious"),
        ])
        let summary = try! #require(history.summary())
        #expect(summary.thermalCounts["nominal"] == 2)
        #expect(summary.thermalCounts["serious"] == 1)
    }

    @Test func emptyHistoryHasNoSummary() {
        #expect(MetricsHistory().summary() == nil)
        #expect(MetricsHistory().memorySparkline().isEmpty)
    }

    @Test func sparklineSpansTheWindowAndTracksMagnitude() {
        let low = MetricsHistory(samples: (0..<20).map { sample(Double($0) * 60, 5) })
        let high = MetricsHistory(samples: (0..<20).map { sample(Double($0) * 60, 100) })
        let lowLine = low.memorySparkline(width: 10)
        let highLine = high.memorySparkline(width: 10)
        #expect(lowLine.count == 10)
        #expect(highLine.count == 10)
        // Low memory uses a low block, high memory a high block.
        #expect(lowLine.first == "▁")
        #expect(highLine.first == "█")
    }

    @Test func historyRoundTripsThroughJSON() throws {
        let history = MetricsHistory(samples: [sample(0, 40, thermal: "fair", rss: 123), sample(60, nil)])
        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(MetricsHistory.self, from: data)
        #expect(decoded == history)
    }
}
