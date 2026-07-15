// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

protocol MonitorBearerHTTPClient: HTTPClient {
    func get(_ url: URL, bearerToken: String, timeout: TimeInterval) async -> HTTPOutcome
    func post(_ url: URL, body: Data, bearerToken: String, timeout: TimeInterval) async -> HTTPOutcome
}

/// Adds one Keychain-sourced bearer to runner requests without exposing that
/// credential to the Codable target or the monitoring core.
struct MonitorBearerRunnerHTTPClient: HTTPClient, Sendable {
    let base: any MonitorBearerHTTPClient
    let token: String

    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        await base.get(url, bearerToken: token, timeout: timeout)
    }

    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome {
        await base.post(url, body: body, bearerToken: token, timeout: timeout)
    }
}

struct MonitorMissingRunnerCredentialHTTPClient: HTTPClient, Sendable {
    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        .failure("This runner requires a bearer credential, but none is available in Keychain.")
    }

    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome {
        .failure("This runner requires a bearer credential, but none is available in Keychain.")
    }
}

/// Sandboxed, outbound-only runner transport. Redirects are refused so a runner
/// cannot make an inference POST escape to another host, and response bodies are
/// capped so a broken endpoint cannot grow the menu app without bound.
final class MonitorHTTPClient: HTTPClient, MonitorAuthenticatedHTTPClient,
                               MonitorBearerHTTPClient, @unchecked Sendable {
    private static let maxResponseBytes = 16 * 1024 * 1024
    private let session: URLSession

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForResource = 300
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(
            configuration: configuration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil)
    }

    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = timeout
        return await send(request)
    }

    func get(_ url: URL, bearerToken: String, timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return await send(request)
    }

    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return await send(request)
    }

    func post(_ url: URL,
              body: Data,
              bearerToken: String,
              timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return await send(request)
    }

    private func send(_ request: URLRequest) async -> HTTPOutcome {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("The endpoint did not return an HTTP response.")
            }
            var data = Data()
            var chunk: [UInt8] = []
            chunk.reserveCapacity(8192)
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if chunk.count == 8192 {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    guard data.count <= Self.maxResponseBytes else {
                        return .failure("The runner response was larger than 16 MB.")
                    }
                }
            }
            data.append(contentsOf: chunk)
            guard data.count <= Self.maxResponseBytes else {
                return .failure("The runner response was larger than 16 MB.")
            }
            if (200..<300).contains(http.statusCode) { return .ok(data) }
            return .http(status: http.statusCode, body: data)
        } catch is CancellationError {
            return .failure("The check was cancelled.")
        } catch let error as URLError {
            return Self.outcome(for: error)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func outcome(for error: URLError) -> HTTPOutcome {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
            return .refused
        case .notConnectedToInternet, .dataNotAllowed:
            return .failure("The network is unavailable. For a local runner, allow Hearth Monitor in System Settings → Privacy & Security → Local Network.")
        case .appTransportSecurityRequiresSecureConnection:
            return .failure("macOS blocked this insecure HTTP connection. Use HTTPS, or a local/private endpoint intended for HTTP.")
        default:
            return .failure(error.localizedDescription)
        }
    }
}
