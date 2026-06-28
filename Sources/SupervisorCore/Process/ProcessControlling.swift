// SPDX-License-Identifier: MIT

import Foundation

/// A fully described child process: what to run, with which arguments, and which
/// environment overrides to layer on top of the parent environment at spawn.
///
/// Setting the environment here, at spawn, is how managed mode sidesteps the
/// `OLLAMA_HOST` launchd env trap by construction: the supervisor owns the child
/// and decides its environment, rather than inheriting whatever a launchd plist
/// did or did not export.
public struct ProcessSpec: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    /// Overrides merged on top of the parent process environment at spawn time.
    public var environmentOverrides: [String: String]

    public init(executableURL: URL,
                arguments: [String] = [],
                environmentOverrides: [String: String] = [:]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
    }
}

/// How a child process ended. Enough information for a pure exit classifier to
/// tell a clean stop from a crash from an out of memory kill.
public struct ProcessExit: Sendable, Equatable {
    /// The exit status. For a process killed by a signal this is conventionally
    /// reported as the negative or 128 plus signal value by some shells; here we
    /// keep the raw `terminationStatus` and record the signal separately.
    public var code: Int32
    /// True when the process was terminated by a signal rather than exiting.
    public var wasSignaled: Bool
    /// The signal number when `wasSignaled` is true.
    public var signal: Int32?

    public init(code: Int32, wasSignaled: Bool = false, signal: Int32? = nil) {
        self.code = code
        self.wasSignaled = wasSignaled
        self.signal = signal
    }
}

/// A point in time snapshot of a child process: is it alive, how did it exit if
/// not, and the most recent captured stderr lines (used for exit classification
/// and for the Open Logs affordance, never for inference).
public struct ProcessStatus: Sendable, Equatable {
    public var isAlive: Bool
    public var exit: ProcessExit?
    public var recentStderr: [String]

    public init(isAlive: Bool, exit: ProcessExit? = nil, recentStderr: [String] = []) {
        self.isAlive = isAlive
        self.exit = exit
        self.recentStderr = recentStderr
    }
}

/// An opaque handle to a spawned child. Opaque and `Sendable` so it can cross the
/// actor boundary between the engine and the process controller without dragging
/// a live `Foundation.Process` reference along with it.
public struct ProcessHandleID: Hashable, Sendable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

/// Process control behind a protocol. The real implementation drives
/// `Foundation.Process`; the test implementation is a scriptable fake.
public protocol ProcessControlling: Sendable {
    /// Spawn the described process. Throws if the binary cannot be launched.
    func spawn(_ spec: ProcessSpec) throws -> ProcessHandleID

    /// The current status of a previously spawned handle. An unknown handle
    /// reports not alive.
    func status(_ id: ProcessHandleID) -> ProcessStatus

    /// Ask the process to terminate. Best effort; liveness is confirmed later
    /// through `status`.
    func terminate(_ id: ProcessHandleID)
}
