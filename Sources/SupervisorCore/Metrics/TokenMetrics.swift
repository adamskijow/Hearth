// SPDX-License-Identifier: MIT

import Foundation

/// A throughput sample extracted from one generation response.
public struct TokenSample: Sendable, Equatable {
    /// Generated (completion) tokens in the response.
    public var evalCount: Int
    /// Generation wall time in nanoseconds, when the runner reported one
    /// (Ollama's `eval_duration`); nil for OpenAI-style bodies, which carry
    /// counts but not timing.
    public var evalDurationNanoseconds: Int64?

    public init(evalCount: Int, evalDurationNanoseconds: Int64? = nil) {
        self.evalCount = evalCount
        self.evalDurationNanoseconds = evalDurationNanoseconds
    }

    public var tokensPerSecond: Double? {
        guard let nanoseconds = evalDurationNanoseconds, nanoseconds > 0 else { return nil }
        return Double(evalCount) / (Double(nanoseconds) / 1_000_000_000)
    }
}

/// Scans the response side of a proxied runner connection for the throughput
/// numbers the runner itself reports, without buffering bodies or touching
/// request content. Ollama's final stream object carries `"eval_count"` and
/// `"eval_duration"`; OpenAI-compatible bodies carry
/// `"completion_tokens"`. The scan is a byte-pattern match over the stream,
/// deliberately tolerant of chunk boundaries (a small tail is carried between
/// chunks), and deliberately approximate: it is a metrics tap, not a parser of
/// record. Nothing scanned is ever stored beyond the extracted numbers.
public struct TokenStreamScanner: Sendable {
    private var tail = Data()
    private var pendingEvalCount: Int?
    /// Keys longer than this never straddle more than one boundary.
    private static let overlap = 64

    public init() {}

    /// Feed response bytes; returns any completed samples they revealed.
    public mutating func ingest(_ chunk: Data) -> [TokenSample] {
        var window = tail
        window.append(chunk)
        var samples: [TokenSample] = []

        for count in Self.integers(after: "\"completion_tokens\":", in: window) {
            samples.append(TokenSample(evalCount: count))
        }
        let evalCounts = Self.integers(after: "\"eval_count\":", in: window)
        let evalDurations = Self.integers(after: "\"eval_duration\":", in: window)
        // Ollama emits eval_count then eval_duration in the same final object;
        // pair them in order, carrying an unpaired count across chunks.
        var counts = evalCounts
        if let pending = pendingEvalCount { counts.insert(pending, at: 0); pendingEvalCount = nil }
        for (index, duration) in evalDurations.enumerated() where index < counts.count {
            samples.append(TokenSample(evalCount: counts[index], evalDurationNanoseconds: Int64(duration)))
        }
        if evalDurations.count < counts.count {
            pendingEvalCount = counts.last
        }

        tail = window.suffix(Self.overlap)
        return samples
    }

    /// Every integer directly following `key` in `data` (optionally after
    /// whitespace), in order.
    static func integers(after key: String, in data: Data) -> [Int] {
        let pattern = Data(key.utf8)
        var results: [Int] = []
        var searchStart = data.startIndex
        while let range = data.range(of: pattern, in: searchStart..<data.endIndex) {
            var index = range.upperBound
            while index < data.endIndex, data[index] == UInt8(ascii: " ") { index = data.index(after: index) }
            var value = 0
            var sawDigit = false
            while index < data.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(data[index]) {
                value = value * 10 + Int(data[index] - UInt8(ascii: "0"))
                sawDigit = true
                index = data.index(after: index)
            }
            // A number cut off by the chunk boundary is left for the next pass
            // via the carried tail; only complete numbers count.
            if sawDigit, index < data.endIndex { results.append(value) }
            searchStart = range.upperBound
        }
        return results
    }
}

/// Accumulated throughput numbers for the metrics endpoints. Thread safe; the
/// proxy records from its connection queue while the control server snapshots.
public final class TokenMetricsStore: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var generationRequests: Int
        public var generationTokensTotal: Int
        public var lastTokensPerSecond: Double?
    }

    private let lock = NSLock()
    private var requests = 0
    private var tokens = 0
    private var lastRate: Double?

    public init() {}

    public func record(_ sample: TokenSample) {
        lock.withLock {
            requests += 1
            tokens += sample.evalCount
            if let rate = sample.tokensPerSecond { lastRate = rate }
        }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(generationRequests: requests, generationTokensTotal: tokens, lastTokensPerSecond: lastRate)
        }
    }
}
