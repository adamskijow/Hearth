// SPDX-License-Identifier: MIT

import Foundation
import Network
import SupervisorCore

/// A byte-for-byte TCP relay with passive HTTP/1.1 activity observation and a
/// best-effort throughput scanner. Unknown framing never changes forwarded data;
/// it only withholds inference checks and automatic inference recovery.
final class MetricsProxy: @unchecked Sendable {
    private final class ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// Reference semantics keep the streaming parser alive across recursive
    /// receive callbacks without capturing and mutating a local variable in
    /// concurrently executing code.
    private final class ScannerBox: @unchecked Sendable {
        private var scanner: TokenStreamScanner
        init(_ scanner: TokenStreamScanner) { self.scanner = scanner }
        func ingest(_ data: Data) -> [TokenSample] { scanner.ingest(data) }
    }

    private let listener: NWListener
    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let store: TokenMetricsStore
    private let queue = DispatchQueue(label: "com.hearth.metrics-proxy")
    private let activeLock = NSLock()
    private var active = 0
    private var ready = false
    private var managedGeneration: UUID?
    private var stopped = false
    private var pairs: [UUID: RelayPair] = [:]
    private let activityStore: ClientActivityStore
    // Preserve cancellation uncertainty across proxy/config reloads for the same
    // upstream. Only framing state and bounded transient headers are retained; no body storage or disk logging.
    private static let registry = ActivityRegistry()
    private final class ActivityRegistry: @unchecked Sendable {
        let lock = NSLock()
        var stores: [String: ClientActivityStore] = [:]
        func store(_ key: String) -> ClientActivityStore {
            lock.withLock {
                if let store = stores[key] { return store }
                let store = ClientActivityStore()
                stores[key] = store
                return store
            }
        }
    }

    func activity() -> ClientActivity {
        var value = activityStore.snapshot()
        value.available = activeLock.withLock { ready }
        return value
    }

    func beforeManagedSpawn() {
        queue.sync {
            cancelPairs()
            managedGeneration = activityStore.beginManagedGeneration()
        }
    }

    func beforeManagedTermination(_ witness: (@Sendable () -> Bool)?) {
        queue.sync {
            cancelPairs()
            if let generation = managedGeneration {
                activityStore.endManagedGeneration(generation, whenGone: witness)
                managedGeneration = nil
            }
        }
    }

    private func cancelPairs() {
        for pair in Array(pairs.values) { pair.cancel() }
        pairs.removeAll()
    }

    /// Legacy connection count; request-aware callers use activity().
    func inFlightConnections() -> Int {
        activeLock.withLock { active }
    }

    /// True after a framed client request has crossed this managed generation.
    /// Observation remains partial: direct runner traffic bypasses this listener.
    func hasObservedClientTraffic() -> Bool {
        activity().observedRequest
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
        self.activityStore = Self.registry.store("\(upstreamHost):\(upstreamPort)")
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.activeLock.withLock {
                if case .ready = state, !self.stopped { self.ready = true } else { self.ready = false }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        activeLock.withLock { ready = false; stopped = true }
        listener.cancel()
        // Cancellation retains uncertainty for unfinished server work. Cancel
        // accepted pairs too; stopping only the listener left hidden relays alive.
        queue.sync { cancelPairs() }
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
        let cancelConnections: () -> Void
        init(cancelConnections: @escaping () -> Void, onClose: @escaping () -> Void) {
            self.cancelConnections = cancelConnections
            self.onClose = onClose
        }
        var isClosed: Bool { lock.withLock { closed } }
        func cancel() { cancelConnections(); close() }

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
        guard activeLock.withLock({ ready }) else { downstream.cancel(); return }
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort)!,
            using: .tcp
        )
        let id = UUID()
        activeLock.withLock { active += 1 }
        activityStore.open(id)
        let down = ConnectionBox(downstream)
        let up = ConnectionBox(upstream)
        let pair = RelayPair(cancelConnections: {
            down.connection.cancel()
            up.connection.cancel()
        }) { [weak self] in
            guard let self else { return }
            self.activeLock.withLock { self.active -= 1 }
            self.activityStore.close(id)
            self.queue.async { self.pairs.removeValue(forKey: id) }
        }
        pairs[id] = pair
        // A failed state can arrive before buffered receive data and clean EOF.
        // Let the receive/send completions drain or report their own error;
        // cross-cancelling here can truncate pipelined replies after half-close.
        // Explicit cancellation still releases the pair. Waiting is failure:
        // this is a local runner, not a connection to retry invisibly.
        let teardown: @Sendable (NWConnection.State) -> Void = { state in
            switch state {
            case .cancelled, .waiting:
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
        relay(from: down, to: up, scanner: nil, pair: pair, id: id, upstream: false)
        // Response side: runner -> client, scanned for throughput numbers.
        relay(from: up, to: down, scanner: ScannerBox(TokenStreamScanner()), pair: pair, id: id, upstream: true)
    }

    /// Pump bytes one way. A clean end-of-stream forwards the FIN to the sink
    /// and lets the OTHER direction keep flowing (an HTTP client may half-close
    /// after its request while the response is still streaming back); only an
    /// error, or both directions finishing, tears the pair down. The optional
    /// scanner taps the stream for samples as it passes.
    private func relay(from source: ConnectionBox, to sink: ConnectionBox,
                       scanner: ScannerBox?, pair: RelayPair, id: UUID, upstream: Bool) {
        let store = self.store
        source.connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
            guard !pair.isClosed else { return }
            if let data, !data.isEmpty { self.activityStore.ingest(data, id: id, upstream: upstream) }
            if isComplete || error != nil { self.activityStore.end(id, upstream: upstream, clean: error == nil) }
            let ended = isComplete || error != nil
            if error != nil, data?.isEmpty != false {
                source.connection.cancel()
                sink.connection.cancel()
                pair.close()
                return
            }
            if let data, !data.isEmpty, let scanner {
                for sample in scanner.ingest(data) { store.record(sample) }
            }
            // Keep one stream context through the final FIN so no unfinished
            // send context precedes the final bytes. Data accompanying a receive
            // error is forwarded before teardown; unfinished activity remains unknown.
            sink.connection.send(
                content: (data?.isEmpty ?? true) ? nil : data,
                contentContext: .defaultStream,
                isComplete: ended,
                completion: .contentProcessed { sendError in
                    guard !pair.isClosed else { return }
                    if sendError != nil || error != nil {
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
                    self.relay(from: source, to: sink, scanner: scanner, pair: pair, id: id, upstream: upstream)
                }
            )
        }
    }
}
