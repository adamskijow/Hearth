// SPDX-License-Identifier: MIT

import Foundation

/// Remembers which models were resident when the runner crashed in a way that
/// looks like it did not fit (an out-of-memory kill, or a crash right as a model
/// loaded), across restarts. When one model is the common factor in enough of
/// those incidents inside a window, it is likely too large for this Mac, and
/// Hearth says so instead of letting it crash-loop.
///
/// Pure and windowed: incidents older than the window age out on their own, so a
/// model un-flags once it stops crashing (the user switched to a smaller one, or
/// freed the memory it needed) with no separate reset to get wrong.
public struct ModelFitLedger: Sendable, Equatable {
    struct Incident: Sendable, Equatable {
        let models: Set<String>
        let at: Date
    }

    private var incidents: [Incident] = []
    /// How many incidents in the window before a model is called too large.
    /// Zero (or less) disables the ledger entirely.
    public let threshold: Int
    public let window: TimeInterval

    public init(threshold: Int, window: TimeInterval) {
        self.threshold = threshold
        self.window = window
    }

    /// Record that these models were resident at a fit-related crash.
    public mutating func record(models: [String], at: Date) {
        guard threshold > 0 else { return }
        let set = Set(models)
        guard !set.isEmpty else { return }
        incidents.append(Incident(models: set, at: at))
    }

    /// Models with at least `threshold` incidents still inside the window as of
    /// `now`, sorted. Prunes aged-out incidents as a side effect, so the ledger
    /// does not grow without bound. A model resident in each incident is the
    /// common factor and is what gets flagged; two models always loaded together
    /// both flag, which is honest (one of them is too large).
    public mutating func flaggedModels(now: Date) -> [String] {
        guard threshold > 0 else { return [] }
        incidents.removeAll { now.timeIntervalSince($0.at) > window }
        var counts: [String: Int] = [:]
        for incident in incidents {
            for model in incident.models { counts[model, default: 0] += 1 }
        }
        return counts.filter { $0.value >= threshold }.keys.sorted()
    }
}
