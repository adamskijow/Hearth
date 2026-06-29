// SPDX-License-Identifier: MIT

import Foundation

/// A command the control endpoint understands.
public enum ControlCommand: String, Sendable, Equatable {
    case status
    case start
    case stop
    case restart
}

/// What the transport should do with a control request. The routing and auth
/// decision is pure and lives here so it is unit testable; the actual sockets and
/// the engine calls live in the app.
public enum ControlOutcome: Sendable, Equatable {
    /// Missing or wrong bearer token.
    case unauthorized
    /// Unknown method or path.
    case notFound
    /// A 200 with this already shaped JSON body.
    case status(Data)
    /// A 200 with an HTML body (the browser status page).
    case html(Data)
    /// Perform this side effecting command, then answer 202.
    case perform(ControlCommand)
}

/// Pure routing and auth for the control endpoint.
public enum ControlRouting {
    /// Decide what to do with a request. The token is the configured secret; an
    /// empty token means control is effectively closed and nothing authorizes.
    public static func handle(method: String,
                              path: String,
                              authorization: String?,
                              token: String,
                              state: SupervisorState,
                              now: Date,
                              metrics: SystemMetrics? = nil) -> ControlOutcome {
        if let early = earlyOutcome(method: method, path: path, authorization: authorization, token: token) {
            return early
        }
        // Only an authenticated /status reaches here; it is the one route that
        // needs live supervisor state and a metrics sample.
        return .status(statusJSON(state, now: now, metrics: metrics))
    }

    /// The outcome for every route that needs no supervisor state or metrics, so
    /// the server can answer it without sampling. Returns nil only for an
    /// authenticated GET /status, which the caller then fills with live state.
    /// This keeps an unauthenticated /healthz poll (and a failed-auth request)
    /// from driving a metrics read and an actor hop on every hit.
    public static func earlyOutcome(method: String,
                                    path: String,
                                    authorization: String?,
                                    token: String) -> ControlOutcome? {
        // Unauthenticated liveness: confirms Hearth itself is up, for an uptime
        // monitor or reverse proxy. It reveals nothing about the runner's state,
        // so it does not require the token.
        if isHealthCheck(method: method, path: path) {
            return .status(Data(#"{"status":"ok"}"#.utf8))
        }
        // The browser status page, served unauthenticated: it is a shell that
        // reveals nothing and fetches /status itself with the token the user
        // enters. Everything below still requires the token.
        if method.uppercased() == "GET", trimmedPath(path) == "/" {
            return .html(Data(ControlStatusPage.html.utf8))
        }
        guard isAuthorized(authorization, token: token) else { return .unauthorized }
        guard let command = command(method: method, path: path) else { return .notFound }
        switch command {
        case .status:
            return nil
        case .start, .stop, .restart:
            return .perform(command)
        }
    }

    /// The path with any query string stripped.
    static func trimmedPath(_ path: String) -> String {
        String(path.split(separator: "?").first ?? Substring(path))
    }

    /// The unauthenticated liveness route: GET /healthz only.
    public static func isHealthCheck(method: String, path: String) -> Bool {
        method.uppercased() == "GET" && trimmedPath(path) == "/healthz"
    }

    /// Map an HTTP method and path (query string ignored) to a command. GET / is
    /// the browser status page, handled before this, not a status command.
    public static func command(method: String, path: String) -> ControlCommand? {
        switch (method.uppercased(), trimmedPath(path)) {
        case ("GET", "/status"):
            return .status
        case ("POST", "/start"):
            return .start
        case ("POST", "/stop"):
            return .stop
        case ("POST", "/restart"):
            return .restart
        default:
            return nil
        }
    }

    /// True only when the Authorization header is exactly "Bearer <token>" for a
    /// non empty configured token, compared without an early out on mismatch.
    public static func isAuthorized(_ authorization: String?, token: String) -> Bool {
        guard !token.isEmpty, let authorization else { return false }
        return constantTimeEquals(authorization, "Bearer \(token)")
    }

    /// A compact status document for the phone.
    public static func statusJSON(_ state: SupervisorState, now: Date, metrics: SystemMetrics? = nil) -> Data {
        let payload = StatusPayload(
            phase: state.phase.rawValue,
            models: state.residentModels.map(\.name),
            uptimeSeconds: state.uptime(asOf: now).map { Int($0.rounded()) },
            restartCount: state.restartCount,
            consecutiveFailures: state.consecutiveFailures,
            lastRestartReason: state.lastRestartReason,
            thermal: metrics.flatMap { $0.thermal == .unknown ? nil : $0.thermal.rawValue },
            memoryUsedPercent: metrics?.memoryUsedFraction.map { Int(($0 * 100).rounded()) },
            runnerResidentBytes: metrics?.runnerResidentBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

private struct StatusPayload: Encodable {
    var phase: String
    var models: [String]
    var uptimeSeconds: Int?
    var restartCount: Int
    var consecutiveFailures: Int
    var lastRestartReason: String?
    var thermal: String?
    var memoryUsedPercent: Int?
    var runnerResidentBytes: Int64?
}
