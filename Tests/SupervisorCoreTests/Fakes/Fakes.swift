// SPDX-License-Identifier: MIT

import Foundation
@testable import SupervisorCore

/// A clock the tests control. `now` only moves when a test moves it, and `sleep`
/// never actually waits. Tests drive the engine with `stepOnce` and advance this
/// clock by hand, so there is no real time and no flakiness.
final class ManualClock: SupervisorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private(set) var sleepRequests: [TimeInterval] = []

    init(now: Date) { _now = now }

    var now: Date { lock.withLock { _now } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { sleepRequests.append(seconds) }
    }
}

/// A scriptable process controller. Spawns hand out incrementing handles that
/// start alive; tests mark them dead with a chosen exit and stderr to simulate
/// crashes, OOM kills, or external kills.
final class FakeProcessController: ProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextRaw: UInt64 = 1
    private var statuses: [ProcessHandleID: ProcessStatus] = [:]

    private var _spawnCount = 0
    private var _terminateCount = 0
    private var _lastHandle: ProcessHandleID?
    private var _spawnError: Error?

    var spawnCount: Int { lock.withLock { _spawnCount } }
    var terminateCount: Int { lock.withLock { _terminateCount } }
    var lastHandle: ProcessHandleID? { lock.withLock { _lastHandle } }

    func failNextSpawns(with error: Error) {
        lock.withLock { _spawnError = error }
    }

    func allowSpawns() {
        lock.withLock { _spawnError = nil }
    }

    func spawn(_ spec: ProcessSpec) throws -> ProcessHandleID {
        try lock.withLock {
            if let error = _spawnError { throw error }
            let id = ProcessHandleID(raw: nextRaw)
            nextRaw += 1
            statuses[id] = ProcessStatus(isAlive: true)
            _spawnCount += 1
            _lastHandle = id
            return id
        }
    }

    func status(_ id: ProcessHandleID) -> ProcessStatus {
        lock.withLock { statuses[id] ?? ProcessStatus(isAlive: false) }
    }

    func terminate(_ id: ProcessHandleID) {
        lock.withLock {
            _terminateCount += 1
            let prior = statuses[id]?.recentStderr ?? []
            statuses[id] = ProcessStatus(
                isAlive: false,
                exit: ProcessExit(code: 0, wasSignaled: true, signal: 15),
                recentStderr: prior
            )
        }
    }

    /// Mark a handle dead with a specific exit, as if the child crashed or was
    /// killed out from under the supervisor.
    func simulateExit(_ id: ProcessHandleID, exit: ProcessExit, stderr: [String] = []) {
        lock.withLock {
            statuses[id] = ProcessStatus(isAlive: false, exit: exit, recentStderr: stderr)
        }
    }

    func isAlive(_ id: ProcessHandleID) -> Bool {
        lock.withLock { statuses[id]?.isAlive ?? false }
    }
}

/// A scriptable HTTP client. Returns the outcome set for a URL, or a default.
/// No network is touched.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [String: HTTPOutcome] = [:]
    private var _default: HTTPOutcome

    init(default defaultOutcome: HTTPOutcome = .refused) {
        _default = defaultOutcome
    }

    func set(_ url: URL, _ outcome: HTTPOutcome) {
        lock.withLock { outcomes[url.absoluteString] = outcome }
    }

    func setDefault(_ outcome: HTTPOutcome) {
        lock.withLock { _default = outcome }
    }

    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        lock.withLock { outcomes[url.absoluteString] ?? _default }
    }
}

/// Records the notifications the engine decides to send.
actor FakeNotifier: Notifier {
    private(set) var received: [HearthNotification] = []

    func notify(_ notification: HearthNotification) async {
        received.append(notification)
    }
}

/// Records power assertion hold and release calls and tracks the current state.
final class FakePowerManager: PowerManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _holds = 0
    private var _releases = 0
    private var _held = false

    var holds: Int { lock.withLock { _holds } }
    var releases: Int { lock.withLock { _releases } }
    var isHeld: Bool { lock.withLock { _held } }

    func hold() {
        lock.withLock {
            if !_held { _held = true; _holds += 1 }
        }
    }

    func release() {
        lock.withLock {
            if _held { _held = false; _releases += 1 }
        }
    }
}

// Convenience accessors for asserting on machine effects in tests.
extension MachineOutput {
    var emittedEvents: [SupervisorEvent] {
        effects.compactMap { effect in
            if case .emit(let event) = effect { return event }
            return nil
        }
    }

    var enteredFailing: Bool {
        emittedEvents.contains {
            if case .enteredFailing = $0 { return true }
            return false
        }
    }
}
