// SPDX-License-Identifier: MIT

import Foundation

public struct EventLogEntry: Sendable, Equatable {
    public var at: Date
    public var message: String

    public init(at: Date, message: String) {
        self.at = at
        self.message = message
    }
}

/// Pure helpers for the persisted event log: Hearth's own decisions (down,
/// restart scheduled, recovered, crash loop) written to disk so the history
/// survives a restart, unlike the in-memory recent-events list. The app layer
/// does the file I/O; the formatting and the tail are here so they are testable.
public enum EventLog {
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// One log line: a timestamp and the event description.
    public static func line(timestamp: String, message: String) -> String {
        "\(timestamp)  \(message)"
    }

    /// The audit message for a control-endpoint command, naming the token that
    /// made the request, so a shared endpoint has a "who restarted it" trail.
    public static func auditMessage(command: String, actor: String) -> String {
        "Control: \(command) requested by token \"\(actor)\""
    }

    /// The last `count` non-empty lines of the log's text, oldest first.
    public static func lastLines(_ content: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        return Array(lines.suffix(count))
    }

    /// Parse the persisted `timestamp  message` shape for native history views.
    /// Invalid or future-format lines are ignored by callers, never fatal.
    public static func parse(_ line: String) -> EventLogEntry? {
        guard let separator = line.range(of: "  ") else { return nil }
        let timestamp = String(line[..<separator.lowerBound])
        guard let date = stamp.date(from: timestamp) else { return nil }
        return EventLogEntry(at: date, message: String(line[separator.upperBound...]))
    }

    /// Append a line to an existing body, trimmed to at most `maxLines` lines so
    /// the file cannot grow without bound. Returns the new body (newline ended).
    public static func appended(_ existing: String, line: String, maxLines: Int) -> String {
        var lines = existing.split(whereSeparator: \.isNewline).map(String.init)
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Groups the stable down/recovered event phrases into the incidents an operator
/// actually reasons about: what failed, when, and how long recovery took.
public enum IncidentHistory {
    public struct Incident: Sendable, Equatable {
        public var startedAt: Date
        public var recoveredAt: Date?
        public var reason: String
        public var events: [EventLogEntry]

        public var recoveryTime: TimeInterval? {
            recoveredAt.map { $0.timeIntervalSince(startedAt) }
        }
    }

    public static func build(_ lines: [String]) -> [Incident] {
        var incidents: [Incident] = []
        var current: Incident?

        for entry in lines.compactMap(EventLog.parse) {
            if entry.message.hasPrefix("Down: ") {
                if current == nil {
                    current = Incident(
                        startedAt: entry.at,
                        recoveredAt: nil,
                        reason: String(entry.message.dropFirst("Down: ".count)),
                        events: [entry])
                } else {
                    current?.events.append(entry)
                }
                continue
            }
            guard current != nil else { continue }
            current?.events.append(entry)
            // A process-level Hearth restart begins a fresh session, so the
            // engine emits Became healthy rather than Recovered. It still closes
            // an incident that was left open in the persisted prior session.
            if entry.message == "Recovered" || entry.message == "Became healthy" {
                current?.recoveredAt = entry.at
                if let finished = current { incidents.append(finished) }
                current = nil
            }
        }
        if let current { incidents.append(current) }
        return incidents
    }
}
