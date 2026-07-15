// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore
import Testing
@testable import HearthMonitor

private final class MonitorURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    static func install(_ value: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Monitor HTTP transport guidance", .serialized)
struct MonitorHTTPClientTests {
    private func client() -> MonitorHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MonitorURLProtocolStub.self]
        return MonitorHTTPClient(configuration: configuration)
    }

    @Test("Common transport failures keep distinct, actionable outcomes")
    func mapsTransportErrors() {
        #expect(MonitorHTTPClient.outcome(for: URLError(.timedOut)) == .timedOut)
        #expect(MonitorHTTPClient.outcome(for: URLError(.cannotConnectToHost)) == .refused)

        guard case .failure(let localNetwork) = MonitorHTTPClient.outcome(
            for: URLError(.notConnectedToInternet)) else {
            Issue.record("expected local-network guidance")
            return
        }
        #expect(localNetwork.contains("Local Network"))
        #expect(localNetwork.contains("System Settings"))

        guard case .failure(let ats) = MonitorHTTPClient.outcome(
            for: URLError(.appTransportSecurityRequiresSecureConnection)) else {
            Issue.record("expected ATS guidance")
            return
        }
        #expect(ats.contains("HTTPS"))
        #expect(ats.contains("local/private"))
    }

    @Test("Runner bearer is attached to both read and inference requests")
    func bearerHeaders() async {
        let lock = NSLock()
        var observed: [(String, String?)] = []
        MonitorURLProtocolStub.install { request in
            lock.withLock {
                observed.append((request.httpMethod ?? "", request.value(forHTTPHeaderField: "Authorization")))
            }
            return (HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let base = client()
        let authenticated = MonitorBearerRunnerHTTPClient(base: base, token: "keychain-value")
        let url = URL(string: "https://runner.example.test/api")!
        _ = await authenticated.get(url, timeout: 2)
        _ = await authenticated.post(url, body: Data("{}".utf8), timeout: 2)
        #expect(lock.withLock { observed.map(\.0) } == ["GET", "POST"])
        #expect(lock.withLock { observed.compactMap(\.1) } == [
            "Bearer keychain-value", "Bearer keychain-value"])
    }

    @Test("Actual transport enforces the response-size cap")
    func responseCap() async {
        MonitorURLProtocolStub.install { request in
            let body = Data(repeating: 1, count: 16 * 1024 * 1024 + 1)
            return (HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let outcome = await client().get(
            URL(string: "https://runner.example.test/oversized")!, timeout: 10)
        guard case .failure(let message) = outcome else {
            Issue.record("expected oversized-response failure")
            return
        }
        #expect(message.contains("larger than 16 MB"))
    }
}
