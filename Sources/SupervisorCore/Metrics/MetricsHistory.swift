// SPDX-License-Identifier: MIT

import Foundation

/// One persisted metrics sample, stored compactly so a day of history is a small
/// file. `memoryPercent` is the rounded 0-100 reading, nil when memory was not
/// measurable at that moment.
public struct MetricsSample: Codable, Sendable, Equatable {
    public var at: Date
    public var memoryPercent: Int?
    public var thermal: String
    public var runnerResidentBytes: Int64?

    public init(at: Date, memoryPercent: Int?, thermal: String, runnerResidentBytes: Int64?) {
        self.at = at
        self.memoryPercent = memoryPercent
        self.thermal = thermal
        self.runnerResidentBytes = runnerResidentBytes
    }

    public init(at: Date, metrics: SystemMetrics) {
        self.at = at
        self.memoryPercent = metrics.memoryUsedFraction.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        self.thermal = metrics.thermal.label
        self.runnerResidentBytes = metrics.runnerResidentBytes
    }
}

/// A bounded, persistable ring of metrics samples. Pure: append, cap, and the
/// trend math have no I/O, so they are fully testable. The app persists this to
/// disk and reads it back for `hearth metrics`. The point is to make the slow
/// memory creep that a maintenance restart exists to clear actually visible.
public struct MetricsHistory: Codable, Sendable, Equatable {
    public var samples: [MetricsSample]

    public init(samples: [MetricsSample] = []) { self.samples = samples }

    /// A new history with `sample` appended, dropping the oldest beyond `cap`.
    /// Samples closer together than `minInterval` to the last kept one are
    /// dropped, so on-disk density is bounded no matter how fast the caller ticks.
    public func recording(_ sample: MetricsSample, cap: Int = 2000, minInterval: TimeInterval = 60) -> MetricsHistory {
        if let last = samples.last, sample.at.timeIntervalSince(last.at) < minInterval {
            return self
        }
        var next = samples
        next.append(sample)
        if next.count > cap {
            next.removeFirst(next.count - cap)
        }
        return MetricsHistory(samples: next)
    }

    public func summary() -> MetricsSummary? {
        MetricsSummary(samples)
    }

    /// A unicode block sparkline of the memory series, downsampled to at most
    /// `width` columns. Empty when no memory readings exist.
    public func memorySparkline(width: Int = 40) -> String {
        let memory = samples.compactMap(\.memoryPercent)
        guard !memory.isEmpty else { return "" }
        let blocks = Array("▁▂▃▄▅▆▇█")
        // Downsample by averaging buckets so the line spans the whole window.
        let columns = min(width, memory.count)
        var points: [Int] = []
        for column in 0..<columns {
            let start = column * memory.count / columns
            let end = max(start + 1, (column + 1) * memory.count / columns)
            let bucket = memory[start..<min(end, memory.count)]
            points.append(Int((Double(bucket.reduce(0, +)) / Double(bucket.count)).rounded()))
        }
        return String(points.map { percent -> Character in
            let index = min(blocks.count - 1, max(0, percent * (blocks.count - 1) / 100))
            return blocks[index]
        })
    }
}

/// A read of a `MetricsHistory`: the window it covers, memory current/peak/average
/// and its trend, the peak runner footprint, and time spent in each thermal state.
public struct MetricsSummary: Sendable, Equatable {
    public enum Trend: String, Sendable, Equatable {
        case rising
        case flat
        case falling
    }

    public var count: Int
    public var first: Date
    public var last: Date
    public var currentMemoryPercent: Int?
    public var peakMemoryPercent: Int?
    public var averageMemoryPercent: Int?
    public var memoryTrend: Trend
    public var peakRunnerResidentBytes: Int64?
    /// Thermal label to the number of samples spent in it.
    public var thermalCounts: [String: Int]

    public init?(_ samples: [MetricsSample]) {
        guard let firstSample = samples.first, let lastSample = samples.last else { return nil }
        count = samples.count
        first = firstSample.at
        last = lastSample.at

        let memory = samples.compactMap(\.memoryPercent)
        currentMemoryPercent = samples.last(where: { $0.memoryPercent != nil }).flatMap(\.memoryPercent)
        peakMemoryPercent = memory.max()
        averageMemoryPercent = memory.isEmpty ? nil : Int((Double(memory.reduce(0, +)) / Double(memory.count)).rounded())
        memoryTrend = Self.trend(memory)

        peakRunnerResidentBytes = samples.compactMap(\.runnerResidentBytes).max()

        var counts: [String: Int] = [:]
        for sample in samples { counts[sample.thermal, default: 0] += 1 }
        thermalCounts = counts
    }

    /// Rising or falling if the second half's average memory differs from the
    /// first half's by more than 3 points, else flat. Needs at least four points.
    private static func trend(_ memory: [Int]) -> Trend {
        guard memory.count >= 4 else { return .flat }
        let mid = memory.count / 2
        let firstHalf = memory[..<mid]
        let secondHalf = memory[mid...]
        let avgFirst = Double(firstHalf.reduce(0, +)) / Double(firstHalf.count)
        let avgSecond = Double(secondHalf.reduce(0, +)) / Double(secondHalf.count)
        let delta = avgSecond - avgFirst
        if delta > 3 { return .rising }
        if delta < -3 { return .falling }
        return .flat
    }
}
