// SPDX-License-Identifier: MIT

import Foundation

/// Splits a byte stream into newline-delimited lines, carrying a partial line across
/// chunks and force-flushing a runaway no-newline line past a cap, so a runner that
/// floods stderr without a newline cannot grow the buffer unbounded. Pure (Data in,
/// strings out) so the byte handling is tested without a process or file handles.
public struct StderrLineSplitter {
    private var partial = Data()
    private let maxPartialBytes: Int

    public init(maxPartialBytes: Int = 64 * 1024) {
        self.maxPartialBytes = maxPartialBytes
    }

    /// Append a chunk and return the complete lines it produced (UTF-8; an
    /// undecodable line is dropped). A partial line is held until its newline (or the
    /// cap) arrives.
    public mutating func ingest(_ data: Data) -> [String] {
        partial.append(data)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
        }
        if partial.count > maxPartialBytes {
            if let line = String(data: partial, encoding: .utf8) { lines.append(line) }
            partial.removeAll(keepingCapacity: false)
        }
        return lines
    }

    /// Emit any buffered partial line, for the end of the stream (process close).
    public mutating func flush() -> String? {
        guard !partial.isEmpty else { return nil }
        defer { partial.removeAll() }
        return String(data: partial, encoding: .utf8)
    }
}
