// SPDX-License-Identifier: MIT

import Foundation
import Network
import SupervisorCore

/// The opt-in tokens-per-second tap: a transparent TCP relay in front of the
/// runner. Clients point at the proxy port instead of the runner and every byte
/// is passed through untouched in both directions; the response side is scanned
/// (never buffered, never stored) for the throughput numbers the runner itself
/// reports, which feed `hearth_tokens_per_second` and friends in `/metrics`.
///
/// A relay, not an HTTP implementation, on purpose: streaming generations pass
/// through with no added framing risk, and if the scan misunderstands a body
/// the worst case is a missed sample, never a broken response.
final class MetricsProxy: @unchecked Sendable {
    private final class ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let listener: NWListener
    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let store: TokenMetricsStore
    private let queue = DispatchQueue(label: "com.hearth.metrics-proxy")
    private let activeLock = NSLock()
    private var active = 0

    /// Connections currently open through the proxy, for the graceful-drain
    /// gate on routine restarts.
    func inFlightConnections() -> Int {
        activeLock.withLock { active }
    }

    /// Listens on `host:port` and relays to the runner at `upstreamHost:upstreamPort`.
    init?(host: String, port: Int, upstreamHost: String, upstreamPort: Int, store: TokenMetricsStore) {
        guard port > 0, port <= 65_535, upstreamPort > 0, upstreamPort <= 65_535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        do {
            if host.isEmpty || host == "0.0.0.0" {
                self.listener = try NWListener(using: parameters, on: nwPort)
            } else {
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(host), port: nwPort)
                self.listener = try NWListener(using: parameters)
            }
        } catch {
            return nil
        }
        self.upstreamHost = upstreamHost
        self.upstreamPort = UInt16(upstreamPort)
        self.store = store
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

    /// Tracks one proxied connection pair: balances the accept-side increment
    /// exactly once however many paths report the close, and knows when BOTH
    /// relay directions have finished so a half-close (a client that shuts its
    /// write side after the request) does not tear down the response stream.
    private final class RelayPair: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var finishedDirections = 0
        private let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        /// One direction saw a clean end-of-stream. True once both have.
        func directionFinished() -> Bool {
            lock.withLock {
                finishedDirections += 1
                return finishedDirections >= 2
            }
        }

        func close() {
            let first = lock.withLock { () -> Bool in
                if closed { return false }
                closed = true
                return true
            }
            if first { onClose() }
        }
    }

    private func accept(_ downstream: NWConnection) {
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort)!,
            using: .tcp
        )
        activeLock.withLock { active += 1 }
        let pair = RelayPair { [weak self] in
            guard let self else { return }
            self.activeLock.withLock { self.active -= 1 }
        }
        let down = ConnectionBox(downstream)
        let up = ConnectionBox(upstream)
        // A connection that fails or is torn down outside the relay loops (an
        // unreachable runner, a mid-stream reset) must still release the pair,
        // or a dead upstream would count as in-flight forever and block the
        // drain gate. Waiting is failure here: the runner is local, so "trying
        // to reach it" means it is down.
        let teardown: @Sendable (NWConnection.State) -> Void = { state in
            switch state {
            case .failed, .cancelled, .waiting:
                down.connection.cancel()
                up.connection.cancel()
                pair.close()
            default:
                break
            }
        }
        downstream.stateUpdateHandler = teardown
        upstream.stateUpdateHandler = teardown
        downstream.start(queue: queue)
        upstream.start(queue: queue)
        // Request side: client -> runner, untouched and unscanned.
        relay(from: down, to: up, scanner: nil, pair: pair)
        // Response side: runner -> client, scanned for throughput numbers.
        relay(from: up, to: down, scanner: TokenStreamScanner(), pair: pair)
    }

    /// Pump bytes one way. A clean end-of-stream forwards the FIN to the sink
    /// and lets the OTHER direction keep flowing (an HTTP client may half-close
    /// after its request while the response is still streaming back); only an
    /// error, or both directions finishing, tears the pair down. The optional
    /// scanner taps the stream for samples as it passes.
    private func relay(from source: ConnectionBox, to sink: ConnectionBox,
                       scanner: TokenStreamScanner?, pair: RelayPair) {
        var scanner = scanner
        let store = self.store
        source.connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            if error != nil {
                source.connection.cancel()
                sink.connection.cancel()
                pair.close()
                return
            }
            if let data, !data.isEmpty, scanner != nil {
                for sample in scanner!.ingest(data) { store.record(sample) }
            }
            // Forward the bytes, and the FIN when this direction ended, in one
            // send so ordering is preserved.
            sink.connection.send(
                content: (data?.isEmpty ?? true) ? nil : data,
                contentContext: isComplete ? .finalMessage : .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { sendError in
                    if sendError != nil {
                        source.connection.cancel()
                        sink.connection.cancel()
                        pair.close()
                        return
                    }
                    if isComplete {
                        // This direction is done; the pair closes when both are.
                        if pair.directionFinished() {
                            source.connection.cancel()
                            sink.connection.cancel()
                            pair.close()
                        }
                        return
                    }
                    self?.relay(from: source, to: sink, scanner: scanner, pair: pair)
                }
            )
        }
    }
}
