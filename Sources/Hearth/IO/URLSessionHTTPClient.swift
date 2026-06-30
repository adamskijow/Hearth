// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// The real HTTP client, a thin wrapper over URLSession that maps transport
/// outcomes onto the coarse `HTTPOutcome` the supervisor reasons about. A read
/// timeout becomes `.timedOut`, which is how an alive but wedged runner is told
/// apart from a healthy one.
final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("non HTTP response")
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

    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("non HTTP response")
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
