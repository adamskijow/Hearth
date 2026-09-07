// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import SupervisorCore

struct HTTPActivityObserverTests {
    private let get = "GET /api/version HTTP/1.1\r\nHost: local\r\n\r\n"
    private let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"

    @Test func completedKeepAliveIsIdleAtEveryFragmentBoundary() {
        for split in 0...get.utf8.count {
            var observer = HTTPActivityObserver()
            let data = Data(get.utf8)
            observer.ingestRequest(data.prefix(split))
            if split > 0 { #expect(!observer.isIdle) }
            observer.ingestRequest(data.dropFirst(split))
            #expect(observer.activeRequests == 1)
            for byte in reply.utf8 { observer.ingestResponse(Data([byte])) }
            #expect(observer.isIdle)
            #expect(observer.completedRequests == 1)
            #expect(observer.observedRequest)
            observer.ingestRequest(Data(get.utf8))
            observer.ingestResponse(Data(reply.utf8))
            #expect(observer.isIdle)
            #expect(observer.completedRequests == 2)
        }
    }

    @Test func uploadStreamingAndTrailersRemainActiveUntilComplete() {
        var observer = HTTPActivityObserver()
        for byte in "POST /api/generate HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n".utf8 {
            observer.ingestRequest(Data([byte]))
            #expect(!observer.isIdle)
        }
        observer.ingestResponse(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\n\r\n".utf8))
        #expect(observer.activeRequests == 1)
        observer.ingestResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        // Arbitrarily long silent prefill requires no timeout-based guessing.
        #expect(observer.activeRequests == 1)
        for byte in "3\r\nabc\r\n0\r\nX-Final: yes\r\n".utf8 {
            observer.ingestResponse(Data([byte]))
            #expect(!observer.isIdle)
        }
        observer.ingestResponse(Data("\r\n".utf8))
        #expect(observer.isIdle)
    }

    @Test func pipelinedMethodsAndBodylessResponsesStayAssociated() {
        var observer = HTTPActivityObserver()
        observer.ingestRequest(Data(("HEAD / HTTP/1.1\r\n\r\n" + get + get + get).utf8))
        #expect(observer.activeRequests == 4)
        observer.ingestResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\nHTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 304 Not Modified\r\n\r\n".utf8))
        #expect(observer.activeRequests == 1)
        observer.ingestResponse(Data(reply.utf8))
        #expect(observer.isIdle)
        #expect(observer.completedRequests == 4)
    }

    @Test func earlyFinalResponseCannotConcealOngoingUpload() {
        var observer = HTTPActivityObserver()
        observer.ingestRequest(Data("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nx".utf8))
        observer.ingestResponse(Data("HTTP/1.1 413 Too Large\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(observer.unknown)
        #expect(!observer.isIdle)
    }

    @Test func cleanHalfCloseAndCloseDelimitedResponse() {
        var observer = HTTPActivityObserver()
        observer.ingestRequest(Data(get.utf8))
        observer.end(upstream: false, clean: true)
        #expect(!observer.unknown)
        observer.ingestResponse(Data("HTTP/1.0 200 OK\r\n\r\nbody".utf8))
        #expect(!observer.isIdle)
        observer.end(upstream: true, clean: true)
        #expect(observer.isIdle)
    }

    @Test(arguments: [
        "POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 18446744073709551616\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: +2\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "GET / HTTP/1.1\r\nBad Header: x\r\n\r\n",
        "GET / HTTP/1.1\nHost: x\n\n",
        "GET /bad\tpath HTTP/1.1\r\n\r\n",
        "CONNECT localhost:80 HTTP/1.1\r\n\r\n",
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        "GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"
    ])
    func unsupportedOrAmbiguousFramingNeverLooksIdle(request: String) {
        var observer = HTTPActivityObserver()
        observer.ingestRequest(Data(request.utf8))
        #expect(observer.unknown)
        observer.ingestResponse(Data(reply.utf8))
        observer.end(upstream: true, clean: true)
        #expect(!observer.isIdle)
    }

    @Test(arguments: ["xyz\r\n", "10000000000000000\r\n", "2;extension=yes\r\n{}\r\n0\r\n\r\n", "1\r\nxXX"])
    func unsupportedChunksRemainUnknown(chunk: String) {
        var observer = HTTPActivityObserver()
        observer.ingestRequest(Data(get.utf8))
        observer.ingestResponse(Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunk).utf8))
        #expect(observer.unknown)
    }

    @Test func truncationAndParserLimitsAreConservative() {
        var truncated = HTTPActivityObserver()
        truncated.ingestRequest(Data(get.utf8))
        truncated.ingestResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nx".utf8))
        truncated.end(upstream: true, clean: true)
        #expect(truncated.unknown)
        var huge = HTTPActivityObserver()
        huge.ingestRequest(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "x", count: 9000)).utf8))
        #expect(huge.unknown)
        var pipelined = HTTPActivityObserver()
        pipelined.ingestRequest(Data(String(repeating: get, count: 33).utf8))
        #expect(pipelined.unknown)
        var tls = HTTPActivityObserver()
        tls.ingestRequest(Data([22, 3, 1]))
        #expect(!tls.isIdle) // unsupported partial data cannot be mistaken for an idle socket
        tls.end(upstream: false, clean: false)
        #expect(tls.unknown)
    }

    @Test func cancellationUncertaintySurvivesCloseAndUnrelatedSuccess() {
        let store = ClientActivityStore()
        store.setAvailable(true)
        let cancelled = UUID()
        store.open(cancelled)
        store.ingest(Data(get.utf8), id: cancelled, upstream: false)
        store.close(cancelled)
        #expect(store.snapshot().activeRequests == 0)
        #expect(store.snapshot().uncertain)
        let other = UUID()
        store.open(other)
        store.ingest(Data(get.utf8), id: other, upstream: false)
        store.ingest(Data(reply.utf8), id: other, upstream: true)
        store.close(other)
        #expect(store.snapshot().blocksInference)
        let generation = store.beginManagedGeneration()
        store.endManagedGeneration(generation, whenGone: { true })
        #expect(store.snapshot().blocksInference) // cannot clear earlier unowned work
    }

    @Test func terminationProofClearsOnlyItsOwnGeneration() {
        let store = ClientActivityStore()
        store.setAvailable(true)
        let old = store.beginManagedGeneration()
        let cancelled = UUID()
        store.open(cancelled)
        store.ingest(Data(get.utf8), id: cancelled, upstream: false)
        store.close(cancelled)
        store.endManagedGeneration(old, whenGone: { false }) // SIGTERM is not completion
        #expect(store.snapshot().uncertain)
        _ = store.beginManagedGeneration()
        let fresh = UUID()
        store.open(fresh)
        store.ingest(Data(get.utf8), id: fresh, upstream: false)
        store.endManagedGeneration(old, whenGone: { true }) // authoritative group absence
        #expect(!store.snapshot().uncertain)
        #expect(store.snapshot().activeRequests == 1)
        #expect(store.snapshot().observedRequest)
        store.close(fresh)
        #expect(store.snapshot().uncertain) // late old proof cannot erase new cancelled work
    }

    @Test func idlePredecessorStillBlocksUntilItsGroupIsGone() {
        let store = ClientActivityStore()
        store.setAvailable(true)
        let old = store.beginManagedGeneration()
        store.endManagedGeneration(old, whenGone: { false })
        let replacement = store.beginManagedGeneration()
        let request = UUID()
        store.open(request) // the old server may still own the upstream port
        store.ingest(Data(get.utf8), id: request, upstream: false)
        store.close(request)
        store.endManagedGeneration(replacement, whenGone: { true }) // failed bind; new child exited
        #expect(store.snapshot().uncertain)
        store.endManagedGeneration(old, whenGone: { true })
        #expect(!store.snapshot().uncertain)
    }

    @Test func unsolicitedResponseBytesImmediatelyBlockInference() {
        let store = ClientActivityStore()
        store.setAvailable(true)
        let id = UUID()
        store.open(id)
        store.ingest(Data(get.utf8), id: id, upstream: false)
        store.ingest(Data(reply.utf8), id: id, upstream: true)
        #expect(!store.snapshot().blocksInference)
        for byte in "HTTP/1.1 200 OK".utf8 {
            store.ingest(Data([byte]), id: id, upstream: true)
            #expect(store.snapshot().blocksInference)
        }
    }

    @Test func throughputScannerDoesNotTrapOnOversizedNumbers() {
        var scanner = TokenStreamScanner()
        let input = "\"eval_count\":" + String(repeating: "9", count: 100) + ","
        #expect(scanner.ingest(Data(input.utf8)).isEmpty)
        let store = TokenMetricsStore()
        store.record(TokenSample(evalCount: Int.max))
        store.record(TokenSample(evalCount: Int.max))
        #expect(store.snapshot().generationTokensTotal == Int.max)
    }

    @Test func unusedConnectionDoesNotEstablishObservedTraffic() {
        let store = ClientActivityStore()
        store.setAvailable(true)
        let id = UUID()
        store.open(id)
        #expect(store.snapshot().openConnections == 1)
        #expect(!store.snapshot().observedRequest)
        #expect(!store.snapshot().blocksInference)
        store.close(id)
        #expect(!store.snapshot().uncertain)
    }
}
