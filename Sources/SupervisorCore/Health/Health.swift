// SPDX-License-Identifier: MIT

import Foundation

/// Readiness is the second half of the health model. Liveness asks "is the PID
/// alive"; readiness asks "does the API actually answer in time". Readiness is
/// what catches the alive but wedged runner that a plain PID check would call
/// healthy.
public enum Readiness: Sendable, Equatable {
    /// The readiness endpoint answered with success inside the timeout.
    case ready
    /// The endpoint answered 503: the runner is alive and working through a
    /// full queue (Ollama's "server busy"). Busy is not wedged; restarting a
    /// busy runner would kill the very work it is doing.
    case busy
    /// The endpoint answered, but not with success (or the connection was
    /// refused). The listener is up enough to talk but not serving.
    case notReady
    /// The request hung past the timeout. Alive but wedged.
    case timedOut
    /// Readiness was not probed, for example because the process is already dead.
    case unknown

    /// Map a raw HTTP outcome onto a readiness verdict. Pure and total.
    public static func from(_ outcome: HTTPOutcome) -> Readiness {
        switch outcome {
        case .ok:
            return .ready
        case .http(let status, _):
            return status == 503 ? .busy : .notReady
        case .timedOut:
            return .timedOut
        case .refused:
            return .notReady
        case .failure:
            return .notReady
        }
    }
}

/// A single combined health observation: liveness, readiness, the classified
/// exit reason when dead, the resident models when ready, and the recent stderr
/// lines that informed the exit classification.
public struct HealthReport: Sendable, Equatable {
    public var isAlive: Bool
    public var readiness: Readiness
    public var exitReason: ExitReason
    public var models: [ResidentModel]
    public var recentStderr: [String]

    public init(isAlive: Bool,
                readiness: Readiness,
                exitReason: ExitReason = .running,
                models: [ResidentModel] = [],
                recentStderr: [String] = []) {
        self.isAlive = isAlive
        self.readiness = readiness
        self.exitReason = exitReason
        self.models = models
        self.recentStderr = recentStderr
    }

    /// The runner is serving: alive and answering. Busy counts as serving; a
    /// full queue means the runner is doing its job, and treating 503 as a
    /// failure would restart a healthy server under load.
    public var isServing: Bool {
        isAlive && (readiness == .ready || readiness == .busy)
    }
}
