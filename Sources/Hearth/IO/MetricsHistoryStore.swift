// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Persists a bounded `MetricsHistory` to Application Support so `hearth metrics`
/// can show how memory and thermals moved over the retained window, surviving a
/// Hearth restart. Thread-safe; the PressureMonitor calls `record` on its
/// sampling tick, and the CLI reads the file directly.
final class MetricsHistoryStore: @unchecked Sendable {
    static var url: URL {
        AppPaths.supportDirectory.appendingPathComponent("metrics-history.json")
    }

    private let url: URL
    private let lock = NSLock()
    private var history: MetricsHistory

    init(url: URL = MetricsHistoryStore.url) {
        self.url = url
        self.history = Self.load(url)
    }

    /// Append a sample. Storage density is bounded inside `MetricsHistory`, so a
    /// too-soon sample is a no-op and is not written.
    func record(_ metrics: SystemMetrics, at now: Date = Date()) {
        lock.withLock {
            let updated = history.recording(MetricsSample(at: now, metrics: metrics))
            guard updated != history else { return }
            history = updated
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load(_ url: URL = MetricsHistoryStore.url) -> MetricsHistory {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MetricsHistory.self, from: data) else {
            return MetricsHistory()
        }
        return decoded
    }
}
