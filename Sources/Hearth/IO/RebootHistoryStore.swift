// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Persists recovery-reboot timestamps so the loop guard survives the reboots
/// themselves: after a reboot, Hearth reads this back to know it already tried.
enum RebootHistoryStore {
    static var url: URL {
        AppPaths.supportDirectory.appendingPathComponent("reboot-history.json")
    }

    static func load() -> RebootHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(RebootHistory.self, from: data) else {
            return RebootHistory()
        }
        return history
    }

    static func record(_ rebootAt: Date) {
        var history = load()
        // Keep about a week so the loop guard has context but the file stays small.
        let cutoff = rebootAt.addingTimeInterval(-7 * 86_400)
        history.recoveryReboots = history.recoveryReboots.filter { $0 >= cutoff }
        history.recoveryReboots.append(rebootAt)
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
