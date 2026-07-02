// SPDX-License-Identifier: MIT

import Foundation

/// Analytics over the persisted event log: how often the runner went down,
/// how fast it came back, and why. Pure so it is tested without a filesystem;
/// the CLI reads the log lines and hands them here. It parses the same
/// `timestamp  message` lines `EventLog.line` writes, keying off the stable
/// phrases in `StatusText.describe`, and is deliberately forgiving: a line it
/// does not recognize is skipped, never a crash.
public enum EventStats {
    public struct Summary: Sendable, Equatable {
        public var window: (first: Date, last: Date)?
        public var downCount: Int
        public var recoveredCount: Int
        public var crashLoopCount: Int
        public var maintenanceRestarts: Int
        /// Down reasons by category (the `describe` phrasing), most frequent first.
        public var byReason: [(reason: String, count: Int)]
        /// Recovery durations: time from a down to the next recovered.
        public var recoveryTimes: [TimeInterval]

        public var meanRecovery: TimeInterval? {
            guard !recoveryTimes.isEmpty else { return nil }
            return recoveryTimes.reduce(0, +) / Double(recoveryTimes.count)
        }
        public var longestRecovery: TimeInterval? { recoveryTimes.max() }

        public static func == (a: Summary, b: Summary) -> Bool {
            a.downCount == b.downCount && a.recoveredCount == b.recoveredCount
                && a.crashLoopCount == b.crashLoopCount && a.maintenanceRestarts == b.maintenanceRestarts
                && a.byReason.map(\.reason) == b.byReason.map(\.reason)
                && a.byReason.map(\.count) == b.byReason.map(\.count)
                && a.recoveryTimes == b.recoveryTimes
                && a.window?.first == b.window?.first && a.window?.last == b.window?.last
        }
    }

    /// The formatter must match EventLogStore's stamp exactly.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func summarize(_ lines: [String]) -> Summary {
        var downCount = 0, recoveredCount = 0, crashLoopCount = 0, maintenanceRestarts = 0
        var reasonCounts: [String: Int] = [:]
        var recoveryTimes: [TimeInterval] = []
        var firstDate: Date?, lastDate: Date?
        var pendingDownAt: Date?

        for line in lines {
            guard let (date, message) = parse(line) else { continue }
            if firstDate == nil { firstDate = date }
            lastDate = date

            if let reason = message.strippedPrefix("Down: ") {
                downCount += 1
                reasonCounts[reason, default: 0] += 1
                // Keep the earliest un-recovered down, so a burst of downs before
                // one recovery measures from the first, not the last.
                if pendingDownAt == nil { pendingDownAt = date }
            } else if message == "Recovered" {
                recoveredCount += 1
                if let downAt = pendingDownAt {
                    recoveryTimes.append(date.timeIntervalSince(downAt))
                    pendingDownAt = nil
                }
            } else if message.hasPrefix("Failing:") {
                crashLoopCount += 1
            } else if message == "Maintenance restart" {
                maintenanceRestarts += 1
            }
        }

        let byReason = reasonCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (reason: $0.key, count: $0.value) }
        let window = firstDate.flatMap { first in lastDate.map { (first: first, last: $0) } }
        return Summary(window: window, downCount: downCount, recoveredCount: recoveredCount,
                       crashLoopCount: crashLoopCount, maintenanceRestarts: maintenanceRestarts,
                       byReason: byReason, recoveryTimes: recoveryTimes)
    }

    /// A log line is "yyyy-MM-dd HH:mm:ss  message"; two spaces separate them.
    static func parse(_ line: String) -> (Date, String)? {
        guard let separator = line.range(of: "  ") else { return nil }
        let timestamp = String(line[..<separator.lowerBound])
        guard let date = stamp.date(from: timestamp) else { return nil }
        return (date, String(line[separator.upperBound...]))
    }
}

private extension String {
    func strippedPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
