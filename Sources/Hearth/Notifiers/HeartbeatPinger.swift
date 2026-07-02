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
    private var timer: DispatchSourceTimer?
    private let warnLock = NSLock()
    private var warnedFailure = false

    /// Nil when the URL is missing or not an http(s) URL (doctor warns about
    /// that separately). The interval is floored so a typo cannot hammer the
    /// monitor.
    init?(urlString: String?, intervalSeconds: Double, isHealthy: @escaping @Sendable () async -> Bool) {
        guard let raw = urlString?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        self.url = url
        self.interval = max(10, intervalSeconds)
        self.isHealthy = isHealthy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration)
    }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 1, repeating: interval)
        source.setEventHandler { [weak self] in self?.pulse() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func pulse() {
        let isHealthy = self.isHealthy
        let session = self.session
        let url = self.url
        Task.detached { [weak self] in
            guard await isHealthy() else { return }
            do {
                _ = try await session.data(from: url)
                self?.warnLock.withLock { self?.warnedFailure = false }
            } catch {
                // One line per failure streak: a broken heartbeat means the
                // user's monitor will alert "down" while the runner is fine.
                guard let self else { return }
                let firstOfStreak: Bool = self.warnLock.withLock {
                    if self.warnedFailure { return false }
                    self.warnedFailure = true
                    return true
                }
                guard firstOfStreak else { return }
                FileHandle.standardError.write(Data(
                    "Hearth: heartbeat to \(url.host ?? "monitor") failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
