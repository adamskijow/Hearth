// SPDX-License-Identifier: MIT

import Foundation

/// The dead-man's-switch half of alerting: while the runner is healthy, GET a
/// configured URL on an interval (an Uptime Kuma push monitor, a
/// healthchecks.io check). When Hearth, the Mac, or the runner goes down the
/// pulse stops, and the monitor the user already runs does the alerting. Only
/// healthy sends a pulse; a wedged or restarting runner must read as down.
final class HeartbeatPinger: @unchecked Sendable {
    private let url: URL
    private let interval: TimeInterval
    private let isHealthy: @Sendable () async -> Bool
    private let session: URLSession
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pulseTask: Task<Void, Never>?
    private var generation = 0
    private var warnedFailure = false

    /// Nil when the URL is missing or not an http(s) URL (doctor warns about
    /// that separately). The interval is floored so a typo cannot hammer the
    /// monitor.
    init?(urlString: String?, intervalSeconds: Double, session: URLSession? = nil,
          isHealthy: @escaping @Sendable () async -> Bool) {
        guard let raw = urlString?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        self.url = url
        self.interval = max(10, intervalSeconds)
        self.isHealthy = isHealthy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: configuration)
    }

    deinit {
        stop()
        session.invalidateAndCancel()
    }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            generation &+= 1
            let current = generation
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            source.schedule(deadline: .now() + 1, repeating: interval)
            source.setEventHandler { [weak self] in self?.pulse(generation: current) }
            source.resume()
            timer = source
        }
    }

    func stop() {
        let pending = lock.withLock {
            generation &+= 1
            let pending = (timer, pulseTask)
            timer = nil
            pulseTask = nil
            return pending
        }
        // Cancellation handlers may run synchronously; never invoke them while
        // holding the state lock. A concurrent start has its own generation.
        pending.0?.cancel()
        pending.1?.cancel()
    }

    private func isCurrent(_ current: Int) -> Bool {
        lock.withLock { generation == current && timer != nil }
    }

    private func finishPulse(_ current: Int) {
        lock.withLock {
            if generation == current { pulseTask = nil }
        }
    }

    private func pulse(generation current: Int) {
        let isHealthy = self.isHealthy
        let session = self.session
        let url = self.url
        lock.withLock {
            guard generation == current, timer != nil, pulseTask == nil else { return }
            pulseTask = Task { [weak self] in
                defer { self?.finishPulse(current) }
                guard await isHealthy(), !Task.isCancelled,
                      self?.isCurrent(current) == true else { return }
                do {
                    // Task cancellation also cancels a request already in flight.
                    _ = try await session.data(from: url)
                    self?.recordSuccess(current)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.recordFailure(current, error: error)
                }
            }
        }
    }

    private func recordSuccess(_ current: Int) {
        lock.withLock {
            if generation == current { warnedFailure = false }
        }
    }

    private func recordFailure(_ current: Int, error: Error) {
        // One line per failure streak, excluding retired or cancelled pulses.
        let firstOfStreak = lock.withLock {
            guard generation == current, !warnedFailure else { return false }
            warnedFailure = true
            return true
        }
        guard firstOfStreak else { return }
        FileHandle.standardError.write(Data(
            "Hearth: heartbeat to \(url.host ?? "monitor") failed: \(error.localizedDescription)\n".utf8))
    }
}
