// SPDX-License-Identifier: MIT

import Foundation

public struct ClientActivity: Codable, Sendable, Equatable {
    public var available: Bool
    public var openConnections: Int
    public var activeRequests: Int
    public var uncertain: Bool
    public var observedRequest: Bool
    public var blocksInference: Bool { !available || uncertain || activeRequests > 0 }
    public init(available: Bool = true, openConnections: Int = 0, activeRequests: Int = 0,
                uncertain: Bool = false, observedRequest: Bool = false) {
        self.available = available
        self.openConnections = openConnections
        self.activeRequests = activeRequests
        self.uncertain = uncertain
        self.observedRequest = observedRequest
    }
}

/// Bounded framing state per live connection. Closed ambiguous requests leave a
/// latch: socket closure cannot prove the runner stopped working. The owner must
/// preserve this store across listener reloads for the same upstream.
public final class ClientActivityStore: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [UUID: HTTPActivityObserver] = [:]
    private var owners: [UUID: UUID] = [:]
    private var currentOwner: UUID?
    private var unsettled = false // work without a known managed owner
    private var unsettledOwners: Set<UUID> = []
    private var terminationProofs: [UUID: @Sendable () -> Bool] = [:]
    private var observed = false
    private var available = false
    public init() {}
    public func setAvailable(_ value: Bool) { lock.withLock { available = value } }
    public func open(_ id: UUID) {
        lock.withLock {
            connections[id] = HTTPActivityObserver()
            owners[id] = currentOwner
        }
    }
    public func ingest(_ data: Data, id: UUID, upstream: Bool) {
        lock.withLock {
            guard var observer = connections[id] else { return }
            if upstream { observer.ingestResponse(data) } else { observer.ingestRequest(data) }
            observed = observed || observer.observedRequest
            connections[id] = observer
        }
    }
    public func end(_ id: UUID, upstream: Bool, clean: Bool) {
        lock.withLock { connections[id]?.end(upstream: upstream, clean: clean) }
    }
    public func close(_ id: UUID) {
        lock.withLock {
            guard let observer = connections.removeValue(forKey: id) else { return }
            let owner = owners.removeValue(forKey: id)
            guard !observer.isIdle else { return }
            if let owner, unsettledOwners.contains(owner) || unsettledOwners.count < 64 {
                unsettledOwners.insert(owner)
            } else {
                // Bound retained generations; missing ownership/proof stays conservative.
                unsettled = true
            }
        }
    }
    /// Called before spawn, after the relay has synchronously cancelled old pairs.
    /// A new generation cannot erase uncertainty belonging to an earlier runner.
    public func beginManagedGeneration() -> UUID {
        lock.withLock {
            let owner = UUID()
            currentOwner = owner
            observed = false
            return owner
        }
    }
    /// Capture proof before terminating the owned process. Merely requesting
    /// termination, or reaping its leader, does not establish group death.
    public func endManagedGeneration(_ owner: UUID, whenGone: (@Sendable () -> Bool)?) {
        lock.withLock {
            if currentOwner == owner { currentOwner = nil }
            // Keep a shutdown guard even if the old runner looked idle. Until it
            // exits, a newly accepted socket may still reach it instead of the
            // replacement child (whose bind may fail). Clearing the new child's
            // work must not hide that older target.
            if unsettledOwners.contains(owner) || unsettledOwners.count < 64 {
                unsettledOwners.insert(owner)
                if let whenGone { terminationProofs[owner] = whenGone }
            } else {
                unsettled = true
            }
        }
    }
    public func snapshot() -> ClientActivity {
        lock.withLock {
            for (owner, proof) in terminationProofs where proof() {
                unsettledOwners.remove(owner)
                terminationProofs.removeValue(forKey: owner)
            }
            return ClientActivity(available: available, openConnections: connections.count,
                           activeRequests: connections.values.reduce(0) { $0 + $1.activeRequests },
                           uncertain: unsettled || !unsettledOwners.isEmpty || connections.values.contains { $0.unknown },
                           observedRequest: observed)
        }
    }
}
