// SPDX-License-Identifier: MIT

import Foundation

/// Pure helpers for the persisted event log: Hearth's own decisions (down,
/// restart scheduled, recovered, crash loop) written to disk so the history
/// survives a restart, unlike the in-memory recent-events list. The app layer
/// does the file I/O; the formatting and the tail are here so they are testable.
public enum EventLog {
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
