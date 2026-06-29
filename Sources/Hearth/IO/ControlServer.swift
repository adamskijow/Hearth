// SPDX-License-Identifier: MIT

import Foundation
import Network
import SupervisorCore

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
    /// thread safe, so the unchecked box is sound.
    private final class ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let listener: NWListener
    private let token: String
    private let coordinator: SupervisionCoordinator
    private let metrics: MetricsProviding?
    private let queue = DispatchQueue(label: "com.hearth.control")

    init?(host: String, port: Int, token: String, coordinator: SupervisionCoordinator, metrics: MetricsProviding? = nil) {
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
        self.coordinator = coordinator
        self.metrics = metrics
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let box = ConnectionBox(connection)
        connection.start(queue: queue)
        // Drop a connection that has not produced a complete request in time, so a
        // slow trickle cannot hold a connection and its pending receive open. A
        // completed request has already cancelled itself, making this a no-op.
        queue.asyncAfter(deadline: .now() + 10) { [weak box] in
            box?.connection.cancel()
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
                box.connection.cancel()
            } else {
                self.read(box, buffer: buffer)
            }
        }
    }

    private func respond(_ box: ConnectionBox, _ request: HTTPRequestHead) {
        let token = self.token
        let coordinator = self.coordinator
        let metrics = self.metrics
        Task { [weak self] in
            let state = await coordinator.status()
            let outcome = ControlRouting.handle(
                method: request.method,
                path: request.path,
                authorization: request.value(for: "Authorization"),
                token: token,
                state: state,
                now: Date(),
                metrics: metrics?.sample()
            )

            let status: Int
            let body: Data
            var contentType = "application/json"
            switch outcome {
            case .unauthorized:
                status = 401
                body = Self.errorJSON("unauthorized")
            case .notFound:
                status = 404
                body = Self.errorJSON("not found")
            case .status(let data):
                status = 200
                body = data
            case .html(let data):
                status = 200
                body = data
                contentType = "text/html; charset=utf-8"
            case .perform(let command):
                await coordinator.perform(command)
                status = 202
                body = Data(#"{"ok":true,"command":"\#(command.rawValue)"}"#.utf8)
            }
            // If the server was torn down mid-request (the config-reload path),
            // close the connection now rather than leaving it for the deadline.
            if let self {
                self.send(box, status: status, body: body, contentType: contentType)
            } else {
                box.connection.cancel()
            }
        }
    }

    private func send(_ box: ConnectionBox, status: Int, body: Data, contentType: String = "application/json") {
        var header = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        box.connection.send(content: response, completion: .contentProcessed { _ in
            box.connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "OK"
        }
    }

    private static func errorJSON(_ message: String) -> Data {
        Data(#"{"error":"\#(message)"}"#.utf8)
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
