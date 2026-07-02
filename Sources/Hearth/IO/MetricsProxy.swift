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

    private func accept(_ downstream: NWConnection) {
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort)!,
            using: .tcp
        )
        let down = ConnectionBox(downstream)
        let up = ConnectionBox(upstream)
        downstream.start(queue: queue)
        upstream.start(queue: queue)
        // Request side: client -> runner, untouched and unscanned.
        relay(from: down, to: up, scanner: nil)
        // Response side: runner -> client, scanned for throughput numbers.
        relay(from: up, to: down, scanner: TokenStreamScanner())
    }

    /// Pump bytes one way until either side ends, closing both when done. The
    /// optional scanner taps the stream for samples as it passes.
    private func relay(from source: ConnectionBox, to sink: ConnectionBox, scanner: TokenStreamScanner?) {
        var scanner = scanner
        let store = self.store
        source.connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                if scanner != nil {
                    for sample in scanner!.ingest(data) { store.record(sample) }
                }
                sink.connection.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete || error != nil {
                        source.connection.cancel()
                        sink.connection.cancel()
                        return
                    }
                    self?.relay(from: source, to: sink, scanner: scanner)
                })
                return
            }
            if isComplete || error != nil {
                source.connection.cancel()
                sink.connection.cancel()
            } else {
                self?.relay(from: source, to: sink, scanner: scanner)
            }
        }
    }
}
