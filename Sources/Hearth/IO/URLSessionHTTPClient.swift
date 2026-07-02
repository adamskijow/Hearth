// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// The real HTTP client, a thin wrapper over URLSession that maps transport
/// outcomes onto the coarse `HTTPOutcome` the supervisor reasons about. A read
/// timeout becomes `.timedOut`, which is how an alive but wedged runner is told
/// apart from a healthy one.
final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    /// A hard ceiling on a runner response body. The endpoints Hearth reads
    /// (version, the model list, a one-token probe) are kilobytes, so this is a
    /// three-order-of-magnitude margin that only a runner deliberately streaming
    /// an unbounded body to exhaust the supervisor's memory would ever hit.
    private static let maxResponseBytes = 16 * 1024 * 1024

    /// Refuses redirects. The runner is a declared trust boundary: following a
    /// 3xx would let a misbehaving or compromised runner point the probe at some
    /// other host, whose answer would then be scored as the runner's health, and
    /// a redirected deep probe would replay its POST body off-box. A redirect
    /// simply surfaces as its 3xx status, which is not-ready.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A hard wall-clock ceiling per request, well above any legitimate probe
        // (the per-request stall timeout, 2s shallow up to the deep-probe timeout,
        // fires first on a healthy runner). It only bites a runner that trickles
        // bytes just under the stall timeout to keep a probe alive indefinitely;
        // without it that request would never return.
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration,
                                  delegate: NoRedirectDelegate(),
                                  delegateQueue: nil)
    }

    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        return await send(request)
    }

    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return await send(request)
    }

    /// Send the request and read the body with a hard size cap, so a hostile
    /// runner (a declared trust boundary) cannot exhaust the supervisor's memory
    /// with an unbounded response. Streaming the body also lets an oversized reply
    /// be abandoned mid-flight rather than fully buffered first.
    private func send(_ request: URLRequest) async -> HTTPOutcome {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("non HTTP response")
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxResponseBytes {
                    return .failure("runner response exceeded \(Self.maxResponseBytes) bytes")
                }
            }
            if (200..<300).contains(http.statusCode) {
                return .ok(data)
            }
            return .http(status: http.statusCode, body: data)
        } catch let error as URLError {
            return Self.mapURLError(error)
        } catch {
            return .failure(String(describing: error))
        }
    }

    private static func mapURLError(_ error: URLError) -> HTTPOutcome {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
            return .refused
        default:
            return .failure(error.localizedDescription)
        }
    }
}
