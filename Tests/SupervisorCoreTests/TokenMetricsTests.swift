// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The tokens-per-second tap: scanning the response stream for the throughput
/// numbers the runner itself reports, tolerant of chunk boundaries, and the
/// store math the metrics endpoint exposes.
struct TokenMetricsTests {
    @Test func extractsOllamaFinalChunkNumbers() {
        var scanner = TokenStreamScanner()
        let final = #"{"model":"llama3","done":true,"eval_count":128,"eval_duration":2000000000,"prompt_eval_count":10}"#
        let samples = scanner.ingest(Data(final.utf8))
        #expect(samples == [TokenSample(evalCount: 128, evalDurationNanoseconds: 2_000_000_000)])
        #expect(samples[0].tokensPerSecond == 64)
    }

    @Test func survivesAKeySplitAcrossChunks() {
        var scanner = TokenStreamScanner()
        let whole = #"{"done":true,"eval_count":42,"eval_duration":1000000000}"#
        // Split mid-key and mid-number; the carried tail must reassemble it.
        let bytes = Array(whole.utf8)
        var samples: [TokenSample] = []
        for part in [bytes[0..<20], bytes[20..<38], bytes[38...]] {
            samples += scanner.ingest(Data(part))
        }
        #expect(samples == [TokenSample(evalCount: 42, evalDurationNanoseconds: 1_000_000_000)])
    }

    @Test func extractsOpenAIUsageCounts() {
        var scanner = TokenStreamScanner()
        let body = #"{"usage":{"prompt_tokens":9,"completion_tokens":77,"total_tokens":86}}"#
        let samples = scanner.ingest(Data(body.utf8))
        #expect(samples.contains(TokenSample(evalCount: 77)))
        #expect(TokenSample(evalCount: 77).tokensPerSecond == nil)   // no timing reported
    }

    @Test func aStreamWithoutNumbersYieldsNothing() {
        var scanner = TokenStreamScanner()
        #expect(scanner.ingest(Data(#"{"response":"hello","done":false}"#.utf8)).isEmpty)
        #expect(scanner.ingest(Data(repeating: 0x41, count: 100_000)).isEmpty)
    }

    @Test func storeAccumulatesAndSnapshots() {
        let store = TokenMetricsStore()
        store.record(TokenSample(evalCount: 100, evalDurationNanoseconds: 1_000_000_000))
        store.record(TokenSample(evalCount: 50))
        let snapshot = store.snapshot()
        #expect(snapshot.generationRequests == 2)
        #expect(snapshot.generationTokensTotal == 150)
        #expect(snapshot.lastTokensPerSecond == 100)
    }

    @Test func prometheusCarriesTheProxyNumbersOnlyWhenPresent() {
        let state = SupervisorState(phase: .healthy)
        let snapshot = TokenMetricsStore.Snapshot(
            generationRequests: 3, generationTokensTotal: 300, lastTokensPerSecond: 42.5)
        let with = String(decoding: ControlRouting.prometheusText(state, now: Date(), tokens: snapshot), as: UTF8.self)
        #expect(with.contains("hearth_generation_tokens_total 300"))
        #expect(with.contains("hearth_tokens_per_second 42.50"))
        let without = String(decoding: ControlRouting.prometheusText(state, now: Date()), as: UTF8.self)
        #expect(!without.contains("hearth_tokens_per_second"))
    }
}
