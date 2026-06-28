// SPDX-License-Identifier: MIT

import Foundation

/// One step in a size based log rotation. Pure data so the decision can be made
/// and tested in the core; the executable performs the file moves and deletes.
public enum RotationStep: Sendable, Equatable {
    case delete(String)
    case move(from: String, to: String)
}

/// Size based log rotation policy. A 24/7 daemon's runner log grows without
/// bound; this caps it. The decision (rotate or not) and the rename plan are pure
/// and tested here. The actual file I/O lives in the process controller.
public struct LogRotationPolicy: Sendable, Equatable {
    /// Rotate once the active log reaches this many bytes. Zero disables rotation.
    public var maxBytes: Int
    /// How many rotated files to keep (log.1 ... log.N). Zero disables rotation.
    public var keepFiles: Int

    public init(maxBytes: Int, keepFiles: Int) {
        self.maxBytes = maxBytes
        self.keepFiles = keepFiles
    }

    public var isEnabled: Bool {
        maxBytes > 0 && keepFiles >= 1
    }

    public func shouldRotate(currentBytes: Int) -> Bool {
        isEnabled && currentBytes >= maxBytes
    }

    /// The rename plan for rotating `base`, oldest first so nothing is clobbered:
    /// delete base.N, move base.(N-1) to base.N, ..., finally move base to base.1.
    /// Moves whose source does not exist are simply skipped by the executor.
    public func steps(forBase base: String) -> [RotationStep] {
        guard isEnabled else { return [] }
        var steps: [RotationStep] = [.delete("\(base).\(keepFiles)")]
        var index = keepFiles - 1
        while index >= 1 {
            steps.append(.move(from: "\(base).\(index)", to: "\(base).\(index + 1)"))
            index -= 1
        }
        steps.append(.move(from: base, to: "\(base).1"))
        return steps
    }
}
