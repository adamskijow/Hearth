// SPDX-License-Identifier: MIT

import Foundation

/// The admission accounting behind the listener's hard connection cap. The
/// server protects it with the same lock as its live connection dictionary.
struct ControlConnectionBudget {
    private let limit: Int
    private var admitted: Set<UUID> = []

    init(limit: Int = 64) { self.limit = max(1, limit) }

    mutating func admit(_ id: UUID) -> Bool {
        guard admitted.count < limit else { return false }
        admitted.insert(id)
        return true
    }

    mutating func release(_ id: UUID) { admitted.remove(id) }
    mutating func releaseAll() { admitted.removeAll() }
    var count: Int { admitted.count }
}

/// A small, in-memory guard around the private control endpoint. Bearer tokens
/// are deliberately high entropy, but an exposed listener should still not give
/// one peer an unlimited online guessing oracle. A peer that crosses the failure
/// threshold is temporarily refused before token comparison; successful auth
/// clears its history. State intentionally does not survive a Hearth restart.
final class ControlAbuseGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumFailures: Int
    private let window: TimeInterval
    private let now: @Sendable () -> Date
    private var failures: [String: [Date]] = [:]

    init(maximumFailures: Int = 30,
         window: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.maximumFailures = max(1, maximumFailures)
        self.window = max(1, window)
        self.now = now
    }

    /// True while this peer is inside a temporary lockout window.
    func shouldReject(peer: String) -> Bool {
        lock.withLock {
            prune(peer: peer, at: now())
            return (failures[peer]?.count ?? 0) >= maximumFailures
        }
    }

    func recordFailure(peer: String) {
        lock.withLock {
            let instant = now()
            prune(peer: peer, at: instant)
            failures[peer, default: []].append(instant)
        }
    }

    func recordSuccess(peer: String) {
        lock.withLock { failures[peer] = nil }
    }

    private func prune(peer: String, at instant: Date) {
        let cutoff = instant.addingTimeInterval(-window)
        let retained = failures[peer, default: []].filter { $0 > cutoff }
        failures[peer] = retained.isEmpty ? nil : retained
    }
}
