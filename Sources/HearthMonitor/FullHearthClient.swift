// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import SupervisorCore

protocol MonitorAuthenticatedHTTPClient: Sendable {
    func get(_ url: URL, bearerToken: String, timeout: TimeInterval) async -> HTTPOutcome
}

enum FullHearthClientError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case unauthorized
    case forbidden
    case unavailable
    case timedOut
    case http(Int)
    case malformedStatus
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "The full Hearth status address is invalid."
        case .unauthorized:
            return "Full Hearth rejected the token. Paste a current status-only token and try again."
        case .forbidden:
            return "Full Hearth accepted the token but did not allow this status request."
        case .unavailable:
            return "Full Hearth is not accepting connections at this address."
        case .timedOut: return "Full Hearth did not answer in time."
        case .http(let status): return "Full Hearth returned HTTP \(status)."
        case .malformedStatus:
            return "The endpoint answered, but it was not a compatible full Hearth status response."
        case .transport(let message): return "The full Hearth request failed: \(message)"
        }
    }
}

struct FullHearthClient: Sendable {
    let http: any MonitorAuthenticatedHTTPClient

    func status(endpoint: FullHearthEndpoint,
                token: String,
                timeout: TimeInterval = 4) async throws -> FullHearthStatus {
        guard endpoint.validationIssues.isEmpty,
              let url = endpoint.url(path: "/status") else {
            throw FullHearthClientError.invalidEndpoint
        }
        let outcome = await http.get(url, bearerToken: token, timeout: max(1, timeout))
        let data: Data
        switch outcome {
        case .ok(let body): data = body
        case .http(let status, _) where status == 401: throw FullHearthClientError.unauthorized
        case .http(let status, _) where status == 403: throw FullHearthClientError.forbidden
        case .http(let status, _): throw FullHearthClientError.http(status)
        case .timedOut: throw FullHearthClientError.timedOut
        case .refused: throw FullHearthClientError.unavailable
        case .failure(let message): throw FullHearthClientError.transport(message)
        }
        guard let decoded = try? JSONDecoder().decode(FullHearthStatus.self, from: data),
              !decoded.phase.isEmpty,
              !decoded.runner.isEmpty else {
            throw FullHearthClientError.malformedStatus
        }
        return decoded
    }
}
