// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Persists supervisor events to a small, line-capped file next to the runner
/// log, so the recent-activity history survives a Hearth restart and can be read
/// from the menu, `hearth status`, or `hearth events`.
enum EventLogStore {
    static var url: URL {
        AppPaths.logDirectory.appendingPathComponent("events.log")
    }

    static let maxLines = 500

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func append(_ event: SupervisorEvent, at date: Date = Date()) {
        let line = EventLog.line(timestamp: stamp.string(from: date), message: StatusText.describe(event))
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = EventLog.appended(existing, line: line, maxLines: maxLines)
        try? FileManager.default.createDirectory(
            at: AppPaths.logDirectory, withIntermediateDirectories: true)
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The most recent `count` event lines, oldest first.
    static func recent(_ count: Int) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return EventLog.lastLines(content, count: count)
    }
}
