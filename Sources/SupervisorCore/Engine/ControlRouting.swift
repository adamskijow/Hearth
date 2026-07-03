// SPDX-License-Identifier: MIT

import Foundation

/// A command the control endpoint understands.
public enum ControlCommand: String, Sendable, Equatable {
    case status
    case start
    case stop
    case restart
}

/// A named control token, so a shared endpoint can tell whose request a
/// start/stop/restart was (the audit trail) instead of one anonymous secret.
public struct ControlToken: Sendable, Equatable {
    public let name: String
    public let secret: String
    public init(name: String, secret: String) {
        self.name = name
        self.secret = secret
    }
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
    /// A 200 with a Prometheus text exposition body.
    case prometheus(Data)
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
                              namedTokens: [ControlToken] = [],
                              state: SupervisorState,
                              now: Date,
                              runnerKind: String = "unknown",
                              metrics: SystemMetrics? = nil,
                              tokens: TokenMetricsStore.Snapshot? = nil) -> ControlOutcome {
        if let early = earlyOutcome(method: method, path: path, authorization: authorization,
                                    token: token, namedTokens: namedTokens) {
            return early
        }
        // Only authenticated reads that need live state and a metrics sample reach
        // here: /status (JSON) and /metrics (Prometheus exposition).
        if trimmedPath(path) == "/metrics" {
            return .prometheus(prometheusText(state, now: now, runnerKind: runnerKind, metrics: metrics, tokens: tokens))
        }
        return .status(statusJSON(state, now: now, runnerKind: runnerKind, metrics: metrics, tokens: tokens))
    }

    /// The outcome for every route that needs no supervisor state or metrics, so
    /// the server can answer it without sampling. Returns nil only for an
    /// authenticated GET /status, which the caller then fills with live state.
    /// This keeps an unauthenticated /healthz poll (and a failed-auth request)
    /// from driving a metrics read and an actor hop on every hit.
    public static func earlyOutcome(method: String,
                                    path: String,
                                    authorization: String?,
                                    token: String,
                                    namedTokens: [ControlToken] = []) -> ControlOutcome? {
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
        guard authenticate(authorization, token: token, namedTokens: namedTokens) != nil else {
            return .unauthorized
        }
        // Prometheus metrics: authenticated and needs live state, so defer to
        // handle() rather than answering here.
        if method.uppercased() == "GET", trimmedPath(path) == "/metrics" { return nil }
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
    public static func isAuthorized(_ authorization: String?, token: String,
                                    namedTokens: [ControlToken] = []) -> Bool {
        authenticate(authorization, token: token, namedTokens: namedTokens) != nil
    }

    /// The name of the token that authorizes this request, or nil for none. The
    /// primary (unnamed) token authorizes as "default". Every candidate is
    /// checked with no early out, so response timing does not reveal which
    /// token, or how many, matched. This name is the audit-trail actor.
    public static func authenticate(_ authorization: String?, token: String,
                                    namedTokens: [ControlToken] = []) -> String? {
        guard let authorization else { return nil }
        var matched: String?
        if !token.isEmpty, constantTimeEquals(authorization, "Bearer \(token)") {
            matched = "default"
        }
        for named in namedTokens where !named.secret.isEmpty {
            if constantTimeEquals(authorization, "Bearer \(named.secret)") {
                matched = named.name
            }
        }
        return matched
    }

    /// A compact status document for the phone.
    public static func statusJSON(_ state: SupervisorState, now: Date,
                                  runnerKind: String = "unknown",
                                  metrics: SystemMetrics? = nil,
                                  tokens: TokenMetricsStore.Snapshot? = nil) -> Data {
        let payload = StatusPayload(
            phase: state.phase.rawValue,
            runner: runnerKind,
            busy: state.busy,
            models: state.residentModels.map(\.name),
            uptimeSeconds: state.uptime(asOf: now).map { Int($0.rounded()) },
            restartCount: state.restartCount,
            consecutiveFailures: state.consecutiveFailures,
            lastRestartReason: state.lastRestartReason,
            lastDownCategory: state.lastDownCategory,
            lastRestartCategory: state.lastRestartCategory,
            deepProbeConfigured: state.deepProbeConfigured,
            thermal: metrics.flatMap { $0.thermal == .unknown ? nil : $0.thermal.rawValue },
            memoryUsedPercent: metrics?.memoryUsedFraction.map { Int(($0 * 100).rounded()) },
            runnerResidentBytes: metrics?.runnerResidentBytes,
            tokensPerSecond: tokens?.lastTokensPerSecond.map { ($0 * 10).rounded() / 10 },
            generationTokensTotal: tokens?.generationTokensTotal
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    /// A Prometheus text exposition of the same status, so the homelab crowd can
    /// scrape Hearth into Grafana or Uptime Kuma alongside everything else.
    public static func prometheusText(_ state: SupervisorState, now: Date,
                                      runnerKind: String = "unknown",
                                      metrics: SystemMetrics? = nil,
                                      tokens: TokenMetricsStore.Snapshot? = nil) -> Data {
        var lines: [String] = []
        func metric(_ name: String, _ help: String, _ type: String, _ value: String, labels: String = "") {
            lines.append("# HELP \(name) \(help)")
            lines.append("# TYPE \(name) \(type)")
            lines.append("\(name)\(labels) \(value)")
        }
        metric("hearth_up", "Whether Hearth is up and answering.", "gauge", "1")
        // Static identity: which runner this Hearth supervises, as a
        // low-cardinality info metric to join on in queries.
        metric("hearth_runner_info", "The runner Hearth supervises, always 1.", "gauge", "1", labels: "{runner=\"\(runnerKind)\"}")
        metric("hearth_healthy", "Whether the runner is healthy (1) or not (0).", "gauge", state.phase == .healthy ? "1" : "0")
        metric("hearth_busy", "Whether the last probe answered busy (queue full).", "gauge", state.busy ? "1" : "0")
        metric("hearth_phase", "Current supervisor phase, 1 for the active one.", "gauge", "1", labels: "{phase=\"\(state.phase.rawValue)\"}")
        if let category = state.lastDownCategory {
            metric("hearth_last_down", "Most recent failure category this session, 1 for the active one.", "gauge", "1", labels: "{reason=\"\(category)\"}")
        }
        if let category = state.lastRestartCategory {
            metric("hearth_last_restart", "Most recent restart category this session (also covers deliberate restarts), 1 for the active one.", "gauge", "1", labels: "{category=\"\(category)\"}")
        }
        metric("hearth_deep_probe_configured", "Whether the deep readiness probe is configured.", "gauge", state.deepProbeConfigured ? "1" : "0")
        if let failedAt = state.deepProbeLastFailedAt {
            metric("hearth_deep_probe_last_failure_timestamp_seconds", "When the deep probe last failed, unix seconds.", "gauge", String(Int(failedAt.timeIntervalSince1970)))
        }
        metric("hearth_restarts_total", "Restarts this session.", "counter", String(state.restartCount))
        metric("hearth_consecutive_failures", "Consecutive failed probes.", "gauge", String(state.consecutiveFailures))
        if let uptime = state.uptime(asOf: now) {
            metric("hearth_uptime_seconds", "Seconds the runner has been continuously healthy.", "gauge", String(Int(uptime.rounded())))
        }
        metric("hearth_resident_models", "Models the runner currently holds resident.", "gauge", String(state.residentModels.count))
        if let fraction = metrics?.memoryUsedFraction {
            metric("hearth_memory_used_percent", "System memory in use, percent.", "gauge", String(Int((fraction * 100).rounded())))
        }
        if let rss = metrics?.runnerResidentBytes {
            metric("hearth_runner_resident_bytes", "Resident memory of the runner process, bytes.", "gauge", String(rss))
        }
        if let sample = metrics, sample.thermal != .unknown {
            metric("hearth_thermal", "Thermal state, 1 for the active one.", "gauge", "1", labels: "{state=\"\(sample.thermal.rawValue)\"}")
        }
        // Present only when the opt-in metrics proxy is routing generation
        // traffic; the numbers come from what the runner itself reports.
        if let tokens {
            metric("hearth_generation_requests_total", "Generations seen by the metrics proxy.", "counter", String(tokens.generationRequests))
            metric("hearth_generation_tokens_total", "Generated tokens seen by the metrics proxy.", "counter", String(tokens.generationTokensTotal))
            if let rate = tokens.lastTokensPerSecond {
                metric("hearth_tokens_per_second", "Throughput of the most recent generation with timing.", "gauge", String(format: "%.2f", rate))
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        var difference = lhs.count ^ rhs.count
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? Int(lhs[index]) : 0
            let right = index < rhs.count ? Int(rhs[index]) : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}

private struct StatusPayload: Encodable {
    var phase: String
    var runner: String
    var busy: Bool
    var models: [String]
    var uptimeSeconds: Int?
    var restartCount: Int
    var consecutiveFailures: Int
    var lastRestartReason: String?
    var lastDownCategory: String?
    var lastRestartCategory: String?
    var deepProbeConfigured: Bool
    var thermal: String?
    var memoryUsedPercent: Int?
    var runnerResidentBytes: Int64?
    var tokensPerSecond: Double?
    var generationTokensTotal: Int?
}
