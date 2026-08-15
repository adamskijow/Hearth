// SPDX-License-Identifier: MIT

import Foundation
import Network
import SupervisorCore

/// Browser hardening applied to every control response. Keeping this as data
/// makes the boundary testable without opening a real listener.
enum ControlResponseSecurity {
    static let headers: [(String, String)] = [
        ("Cache-Control", "no-store"),
        ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
        ("X-Frame-Options", "DENY"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=()"),
    ]
}

/// A tiny HTTP control endpoint so a phone (over Tailscale, a VPN, or the local
/// network) can check status and start, stop, or restart the runner. The routing
/// and auth decision is pure and tested in SupervisorCore (`ControlRouting`);
/// this file is only the socket transport.
///
/// Every request must carry `Authorization: Bearer <token>`. The server refuses
/// to start without a token. Bind it to localhost or a private interface and put
/// it behind a VPN; it is a control surface, not a public API.
final class ControlServer: @unchecked Sendable {
    /// Network's connection type is not Sendable; box it so closures and tasks
    /// can carry it under Swift's concurrency checking. NWConnection is internally
    /// thread safe, so the unchecked box is sound. `finish` is exactly-once so
    /// every close path releases the server's admission slot.
    private final class ConnectionBox: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        let peer: String
        private let finishLock = NSLock()
        private var didFinish = false
        private let onFinish: @Sendable (UUID) -> Void

        init(_ connection: NWConnection,
             peer: String,
             onFinish: @escaping @Sendable (UUID) -> Void) {
            self.connection = connection
            self.peer = peer
            self.onFinish = onFinish
        }

        func cancel() {
            connection.cancel()
            finish()
        }

        func finish() {
            let first = finishLock.withLock { () -> Bool in
                if didFinish { return false }
                didFinish = true
                return true
            }
            if first { onFinish(id) }
        }
    }

    private let listener: NWListener
    private let token: String
    private let namedTokens: [ControlToken]
    private let runnerKind: String
    private let mode: String
    private let rebootOnWedge: Bool
    private let coordinator: SupervisionCoordinator
    private let metrics: MetricsProviding?
    private let tokenMetrics: TokenMetricsStore?
    /// Called when an authenticated start/stop/restart is performed, with the
    /// command and the name of the token that authorized it, for the audit log.
    private let onControlAction: (@Sendable (ControlCommand, String) -> Void)?
    private let queue = DispatchQueue(label: "com.hearth.control")
    private let abuseGuard: ControlAbuseGuard
    private let connectionsLock = NSLock()
    private var connections: [UUID: ConnectionBox] = [:]
    private var connectionBudget: ControlConnectionBudget
    /// Set once the server is torn down (a config reload replaces it). A request
    /// accepted before the teardown must not drive the now-replaced coordinator.
    private let stoppedLock = NSLock()
    private var stoppedFlag = false
    private var isStopped: Bool { stoppedLock.withLock { stoppedFlag } }

    init?(host: String, port: Int, token: String, coordinator: SupervisionCoordinator,
          namedTokens: [ControlToken] = [],
          runnerKind: String = "unknown",
          mode: String = "managed",
          rebootOnWedge: Bool = false,
          metrics: MetricsProviding? = nil, tokenMetrics: TokenMetricsStore? = nil,
          onControlAction: (@Sendable (ControlCommand, String) -> Void)? = nil,
          maximumConnections: Int = 64,
          abuseGuard: ControlAbuseGuard = ControlAbuseGuard()) {
        guard !token.isEmpty,
              port > 0, port <= 65_535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            if host.isEmpty || host == "0.0.0.0" {
                self.listener = try NWListener(using: parameters, on: nwPort)
            } else {
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(host),
                    port: nwPort
                )
                self.listener = try NWListener(using: parameters)
            }
        } catch {
            return nil
        }
        self.token = token
        self.namedTokens = namedTokens
        self.runnerKind = runnerKind
        self.mode = mode
        self.rebootOnWedge = rebootOnWedge
        self.coordinator = coordinator
        self.metrics = metrics
        self.tokenMetrics = tokenMetrics
        self.onControlAction = onControlAction
        self.connectionBudget = ControlConnectionBudget(limit: maximumConnections)
        self.abuseGuard = abuseGuard
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        stoppedLock.withLock { stoppedFlag = true }
        listener.cancel()
        let open = connectionsLock.withLock { () -> [ConnectionBox] in
            let current = Array(connections.values)
            connections.removeAll()
            connectionBudget.releaseAll()
            return current
        }
        for box in open { box.cancel() }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let peer = Self.peerKey(connection.endpoint)
        let box = ConnectionBox(connection, peer: peer) { [weak self] id in
            guard let self else { return }
            self.connectionsLock.withLock {
                self.connections[id] = nil
                self.connectionBudget.release(id)
            }
        }
        let admitted = connectionsLock.withLock { () -> Bool in
            guard connectionBudget.admit(box.id) else { return false }
            connections[box.id] = box
            return true
        }
        guard admitted, !isStopped else {
            box.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak box] state in
            switch state {
            case .failed, .cancelled:
                box?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Drop a connection that has not produced a complete request in time, so a
        // slow trickle cannot hold a connection and its pending receive open. A
        // completed request has already cancelled itself, making this a no-op.
        queue.asyncAfter(deadline: .now() + 10) { [weak box] in
            box?.cancel()
        }
        read(box, buffer: Data())
    }

    private func read(_ box: ConnectionBox, buffer: Data) {
        box.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { box.connection.cancel(); return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }

            if let request = HTTPRequestHead.parse(buffer) {
                self.respond(box, request)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                box.cancel()
            } else {
                self.read(box, buffer: buffer)
            }
        }
    }

    private func respond(_ box: ConnectionBox, _ request: HTTPRequestHead) {
        let token = self.token
        let namedTokens = self.namedTokens
        let runnerKind = self.runnerKind
        let mode = self.mode
        let rebootOnWedge = self.rebootOnWedge
        let coordinator = self.coordinator
        let metrics = self.metrics
        Task { [weak self] in
            guard let self else { box.cancel(); return }
            let authorization = request.value(for: "Authorization")
            let requiresAuthorization = !ControlRouting.isHealthCheck(
                method: request.method, path: request.path)
                && !(request.method.uppercased() == "GET"
                    && String(request.path.split(separator: "?").first ?? Substring(request.path)) == "/")
            if requiresAuthorization, abuseGuard.shouldReject(peer: box.peer) {
                send(box, status: 429, body: Self.errorJSON("too many failed authentication attempts"))
                return
            }
            // Answer the routes that need no supervisor state or metrics first, so
            // an unauthenticated /healthz poll (or a failed-auth request) does not
            // trigger a metrics sample and a coordinator hop.
            let outcome: ControlOutcome
            if let early = ControlRouting.earlyOutcome(
                method: request.method, path: request.path,
                authorization: authorization, token: token, namedTokens: namedTokens) {
                outcome = early
            } else {
                let state = await coordinator.status()
                outcome = ControlRouting.handle(
                    method: request.method,
                    path: request.path,
                    authorization: authorization,
                    token: token,
                    namedTokens: namedTokens,
                    state: state,
                    now: Date(),
                    runnerKind: runnerKind,
                    mode: mode,
                    rebootOnWedge: rebootOnWedge,
                    metrics: metrics?.sample(),
                    tokens: tokenMetrics?.snapshot(),
                    recentEvents: EventLogStore.recent(10)
                )
            }

            let status: Int
            let body: Data
            var contentType = "application/json"
            switch outcome {
            case .unauthorized:
                abuseGuard.recordFailure(peer: box.peer)
                status = 401
                body = Self.errorJSON("unauthorized")
            case .forbidden:
                abuseGuard.recordSuccess(peer: box.peer)
                status = 403
                body = Self.errorJSON("status-only token cannot perform commands")
            case .notFound:
                if requiresAuthorization { abuseGuard.recordSuccess(peer: box.peer) }
                status = 404
                body = Self.errorJSON("not found")
            case .status(let data):
                if requiresAuthorization { abuseGuard.recordSuccess(peer: box.peer) }
                status = 200
                body = data
            case .html(let data):
                status = 200
                body = data
                contentType = "text/html; charset=utf-8"
            case .prometheus(let data):
                abuseGuard.recordSuccess(peer: box.peer)
                status = 200
                body = data
                contentType = "text/plain; version=0.0.4; charset=utf-8"
            case .perform(let command):
                abuseGuard.recordSuccess(peer: box.peer)
                if isStopped {
                    // The server was torn down (a config reload) after this request
                    // was accepted; do not re-drive the replaced coordinator/engine.
                    status = 503
                    body = Self.errorJSON("server reloading")
                } else {
                    // Record who asked before performing it, so the audit trail
                    // is written even if the command's own event is delayed.
                    if let actor = ControlRouting.authenticate(
                        authorization, token: token, namedTokens: namedTokens) {
                        onControlAction?(command, actor)
                    }
                    await coordinator.perform(command)
                    status = 202
                    body = Data(#"{"ok":true,"command":"\#(command.rawValue)"}"#.utf8)
                }
            }
            // If the server was torn down mid-request (the config-reload path),
            // close the connection now rather than leaving it for the deadline.
            send(box, status: status, body: body, contentType: contentType)
        }
    }

    private func send(_ box: ConnectionBox, status: Int, body: Data, contentType: String = "application/json") {
        var header = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        for (name, value) in ControlResponseSecurity.headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        box.connection.send(content: response, completion: .contentProcessed { _ in
            box.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    private static func errorJSON(_ message: String) -> Data {
        Data(#"{"error":"\#(message)"}"#.utf8)
    }

    private static func peerKey(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _): return String(describing: host)
        case .unix(let path): return "unix:\(path)"
        case .service(let name, let type, let domain, _):
            return "service:\(name).\(type).\(domain)"
        case .url(let url): return "url:\(url.absoluteString)"
        case .opaque(let value): return "opaque:\(String(describing: value))"
        @unknown default: return String(describing: endpoint)
        }
    }
}

/// The parsed head of an HTTP request: method, path, and headers. The body is not
/// read; control commands carry no body.
struct HTTPRequestHead: Sendable {
    let method: String
    let path: String
    private let headers: [(String, String)]

    init(method: String, path: String, headers: [(String, String)]) {
        self.method = method
        self.path = path
        self.headers = headers
    }

    func value(for name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.0.lowercased() == lowered }?.1
    }

    /// Parse once the header terminator is present; returns nil if the head is not
    /// complete yet so the caller keeps reading.
    static func parse(_ data: Data) -> HTTPRequestHead? {
        guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let text = String(data: data[..<terminator.lowerBound], encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return HTTPRequestHead(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }
}
