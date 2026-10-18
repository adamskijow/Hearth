// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Hearth

private final class HeartbeatRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var stopped = 0
    let complete: Bool
    init(complete: Bool) { self.complete = complete }
    var count: Int { lock.withLock { started } }
    var cancellations: Int { lock.withLock { stopped } }
    func didStart() { lock.withLock { started += 1 } }
    func didStop() { lock.withLock { stopped += 1 } }
}

private final class HeartbeatRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URL: HeartbeatRequests] = [:]
    func set(_ requests: HeartbeatRequests?, for url: URL) { lock.withLock { self.requests[url] = requests } }
    func get(_ url: URL?) -> HeartbeatRequests? { lock.withLock { url.flatMap { requests[$0] } } }
}

/// Intercepts only the injected session, so tests never send an external pulse.
private final class HeartbeatProtocol: URLProtocol, @unchecked Sendable {
    static let registry = HeartbeatRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let recorder = Self.registry.get(request.url), let url = request.url else { return }
        recorder.didStart()
        guard recorder.complete else { return } // Hold the request until cancellation.
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.registry.get(request.url)?.didStop() }
}

private actor PendingHealth {
    private var first = true
    private var continuation: CheckedContinuation<Bool, Never>?
    var entered: Bool { continuation != nil }
    func check() async -> Bool {
        guard first else { return true }
        first = false
        // Deliberately ignores cancellation, like an actor hop that has already
        // captured a healthy snapshot but has not returned it to the pinger.
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: true); continuation = nil }
}

struct HeartbeatPingerTests {
    @Test(arguments: [false, true])
    func pendingHealthCannotSendAfterStop(restart: Bool) async throws {
        let (url, session, requests) = fixture(complete: true)
        defer { HeartbeatProtocol.registry.set(nil, for: url); session.invalidateAndCancel() }
        let health = PendingHealth()
        let candidate = HeartbeatPinger(urlString: url.absoluteString, intervalSeconds: 10,
            session: session, isHealthy: { await health.check() })
        let pinger = try #require(candidate)
        defer { pinger.stop() }
        pinger.start()
        var entered = false
        for _ in 0..<150 {
            if await health.entered { entered = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(entered)
        pinger.stop()
        if restart { pinger.start() }
        await health.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(requests.count == 0)
        if restart {
            #expect(await eventually { requests.count == 1 })
            #expect(requests.count == 1)
        }
    }

    @Test func stopCancelsInFlightRequestAndAllowsANewSession() async throws {
        let (url, session, requests) = fixture(complete: false)
        defer { HeartbeatProtocol.registry.set(nil, for: url); session.invalidateAndCancel() }
        let candidate = HeartbeatPinger(urlString: url.absoluteString, intervalSeconds: 10,
            session: session, isHealthy: { true })
        let pinger = try #require(candidate)
        defer { pinger.stop() }
        pinger.start()
        #expect(await eventually { requests.count == 1 })
        pinger.stop()
        #expect(await eventually { requests.cancellations == 1 })
        pinger.start()
        #expect(await eventually { requests.count == 2 })
        pinger.stop()
        #expect(await eventually { requests.cancellations == 2 })
    }

    private func fixture(complete: Bool) -> (URL, URLSession, HeartbeatRequests) {
        let url = URL(string: "https://heartbeat.invalid/\(UUID().uuidString)")!
        let requests = HeartbeatRequests(complete: complete)
        HeartbeatProtocol.registry.set(requests, for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeartbeatProtocol.self]
        return (url, URLSession(configuration: configuration), requests)
    }
}
