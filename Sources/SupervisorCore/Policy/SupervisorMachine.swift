// SPDX-License-Identifier: MIT

import Foundation

/// A side effect the machine asks the engine to perform. The machine itself
/// never touches a process, a socket, the power assertion, or a notifier; it
/// only decides, and returns these for the engine to carry out. That is what
/// makes the whole policy testable with no real I/O.
public enum MachineEffect: Sendable, Equatable {
    /// Spawn a fresh child from the runner's process spec.
    case spawn
    /// Terminate the current child (used when killing a wedged, still alive
    /// process before respawning).
    case kill
    /// Hold the sleep preventing power assertion.
    case holdPower
    /// Release the sleep preventing power assertion.
    case releasePower
    /// Adopt the resident models from the latest probe into published state.
    case updateModels
    /// Emit an event for the UI to log and, if notable, notify on.
    case emit(SupervisorEvent)
}

/// What the machine returns from each transition: the effects to run and how long
/// the engine should wait before its next step.
public struct MachineOutput: Sendable, Equatable {
    public var effects: [MachineEffect]
    public var nextWait: TimeInterval

    public init(effects: [MachineEffect], nextWait: TimeInterval) {
        self.effects = effects
        self.nextWait = nextWait
    }
}

/// The pure restart policy as an explicit state machine. Every method takes the
/// current instant explicitly so there is no hidden clock. Mutating value type:
/// the engine owns one inside its actor; tests drive one directly.
struct SupervisorMachine {
    let config: RestartPolicyConfig

    private(set) var phase: SupervisorPhase = .stopped
    /// When the next respawn is due, while down or failing.
    private(set) var scheduledRespawnAt: Date = .distantFuture
    /// When the current child was spawned, for startup grace.
    private(set) var spawnTime: Date = .distantPast
    /// Consecutive failures since the last recovery. Drives backoff.
    private(set) var consecutiveFailures: Int = 0
    /// Total respawns performed since the last fresh start.
    private(set) var restartCount: Int = 0
    /// Failure timestamps inside the crash loop window.
    private(set) var failureTimestamps: [Date] = []
    /// When the failing phase was entered, if failing.
    private(set) var failingSince: Date? = nil
    /// Whether the current failure streak (since the last return to healthy)
    /// included a real process exit, as opposed to only "alive but not answering"
    /// wedges. Reboot escalation can opt to require this, since a wedge is the one
    /// signal a runner can fake purely through its HTTP responses.
    private(set) var failingStreakHadProcessExit: Bool = false
    /// Start of the current healthy streak, for uptime.
    private(set) var healthySince: Date? = nil
    /// A short description of the most recent restart cause.
    private(set) var lastRestartReason: String? = nil
    /// Bounded category of the most recent failure, for metrics labels.
    private(set) var lastDownCategory: String? = nil
    /// Bounded category of the most recent restart, for metrics labels. Unlike
    /// lastDownCategory (failures only) this also covers deliberate restarts:
    /// wedged, crash, oom, signal, memory-limit, maintenance, manual,
    /// binary-upgrade. Nil until the first restart this session.
    private(set) var lastRestartCategory: String? = nil
    /// When the phase last changed.
    private(set) var lastTransition: Date = Date(timeIntervalSince1970: 0)
    /// Whether the most recent respawn was a routine maintenance restart, so the
    /// return to healthy is quiet (becameHealthy) rather than a pushed recovery.
    private(set) var lastRestartWasMaintenance: Bool = false
    /// Whether the most recent respawn was a user restart of an already-healthy
    /// runner. Nothing failed, so the return to healthy is quiet too; a user
    /// restart of a down or failing runner still announces the recovery.
    private(set) var lastRestartWasManualFromHealthy: Bool = false

    init(config: RestartPolicyConfig) {
        self.config = config
    }

    // MARK: - User and lifecycle transitions

    /// Begin a fresh supervision session: spawn, hold power, reset all counters.
    mutating func start(now: Date) -> MachineOutput {
        resetCounters()
        phase = .starting
        spawnTime = now
        lastTransition = now
        return MachineOutput(
            effects: [.holdPower, .spawn, .emit(.started)],
            nextWait: config.startupProbeInterval
        )
    }

    /// Stop supervising by request: kill the child, release power.
    mutating func stop(now: Date) -> MachineOutput {
        phase = .stopped
        healthySince = nil
        scheduledRespawnAt = .distantFuture
        lastTransition = now
        return MachineOutput(
            effects: [.kill, .releasePower, .emit(.stopped)],
            nextWait: 0
        )
    }

    /// Restart by request: kill and respawn immediately, clear failure history.
    /// A user restart is not a crash, so it does not count toward backoff or the
    /// crash loop window.
    mutating func userRestart(now: Date) -> MachineOutput {
        lastRestartWasManualFromHealthy = phase == .healthy
        consecutiveFailures = 0
        failureTimestamps.removeAll()
        failingSince = nil
        healthySince = nil
        restartCount += 1
        phase = .restarting
        spawnTime = now
        lastRestartReason = "manual restart"
        lastRestartCategory = "manual"
        lastRestartWasMaintenance = false
        lastTransition = now
        return MachineOutput(
            effects: [.holdPower, .kill, .spawn, .emit(.restarted(attempt: restartCount))],
            nextWait: config.startupProbeInterval
        )
    }

    /// The memory-limit watchdog tripped: the healthy runner's resident size
    /// crossed the configured ceiling, the slow-death ladder (growing latency,
    /// then a wedge) that a readiness probe only catches at the end. Same shape
    /// as a maintenance restart, but it emits a notable event: the user set a
    /// limit and should hear when it bites.
    mutating func memoryLimitRestart(residentBytes: Int64, limitBytes: Int64, now: Date) -> MachineOutput {
        consecutiveFailures = 0
        failureTimestamps.removeAll()
        failingSince = nil
        healthySince = nil
        restartCount += 1
        phase = .restarting
        spawnTime = now
        lastRestartReason = "memory limit exceeded"
        lastDownCategory = "memory-limit"
        lastRestartCategory = "memory-limit"
        lastRestartWasMaintenance = true   // the return to healthy is quiet
        lastRestartWasManualFromHealthy = false
        lastTransition = now
        return MachineOutput(
            effects: [.kill, .spawn, .emit(.memoryLimitExceeded(residentBytes: residentBytes, limitBytes: limitBytes))],
            nextWait: config.startupProbeInterval
        )
    }

    /// A scheduled maintenance restart of a healthy runner: cycle it to clear
    /// memory creep. Like a user restart (not a crash, so it clears failure
    /// history and does not count toward backoff), but power is already held and
    /// it emits its own routine event.
    mutating func maintenanceRestart(now: Date, category: String = "maintenance") -> MachineOutput {
        consecutiveFailures = 0
        failureTimestamps.removeAll()
        failingSince = nil
        healthySince = nil
        restartCount += 1
        phase = .restarting
        spawnTime = now
        lastRestartReason = "scheduled maintenance restart"
        lastRestartCategory = category
        lastRestartWasMaintenance = true
        lastRestartWasManualFromHealthy = false
        lastTransition = now
        return MachineOutput(
            effects: [.kill, .spawn, .emit(.maintenanceRestart)],
            nextWait: config.startupProbeInterval
        )
    }

    // MARK: - Time driven respawn

    /// Whether a scheduled respawn is due as of `now`. The engine consults this
    /// while down or failing to decide whether to wait more or respawn.
    func respawnDue(now: Date) -> Bool {
        (phase == .down || phase == .failing) && now >= scheduledRespawnAt
    }

    /// The scheduled backoff or slow retry timer fired: spawn a fresh child and
    /// move to restarting so the engine probes it. This holds even while failing:
    /// the fresh child MUST be probed, or a crash loop could never recover. The
    /// failing context is preserved in `failingSince`, so the slow retry cadence
    /// and the `recovered` (not `becameHealthy`) event survive until it is healthy
    /// again; the `.failing` phase is the wait between retries, `.restarting` is
    /// each retry attempt being probed.
    mutating func respawnNow(now: Date) -> MachineOutput {
        restartCount += 1
        spawnTime = now
        phase = .restarting
        scheduledRespawnAt = .distantFuture
        lastRestartWasMaintenance = false
        lastRestartWasManualFromHealthy = false
        lastTransition = now
        return MachineOutput(
            effects: [.spawn, .emit(.restarted(attempt: restartCount))],
            nextWait: config.startupProbeInterval
        )
    }

    // MARK: - The central observation handler

    /// Feed a health observation in and get the next move out. This is where
    /// liveness, readiness, startup grace, backoff, crash loop detection, and
    /// recovery all come together.
    mutating func observe(_ report: HealthReport, now: Date) -> MachineOutput {
        if report.isServing {
            return handleServing(report, now: now)
        }

        // Not serving. During startup grace, an alive but not yet ready runner is
        // still warming up, not failing.
        let aliveButNotReady = report.isAlive && report.readiness != .ready
        let withinGrace = (phase == .starting || phase == .restarting)
            && now.timeIntervalSince(spawnTime) < config.startupGrace
        if aliveButNotReady && withinGrace {
            return MachineOutput(effects: [], nextWait: config.startupProbeInterval)
        }

        // A real failure.
        let reason: DownReason = report.isAlive ? .wedged : .crashed(report.exitReason)
        return handleFailure(reason, killNeeded: report.isAlive, now: now)
    }

    // MARK: - Internals

    private mutating func handleServing(_ report: HealthReport, now: Date) -> MachineOutput {
        var effects: [MachineEffect] = []

        if phase != .healthy {
            // Transition into healthy. Coming back after a failure restart this
            // session is a recovery (the user got a down or failing alert and
            // wants the all clear); a clean first start is just becoming healthy.
            // A routine maintenance restart and a user restart of an already
            // healthy runner come back quietly; only a return from an actual
            // failure is a pushed all-clear.
            let recovering = restartCount > 0
                && !lastRestartWasMaintenance
                && !lastRestartWasManualFromHealthy
            lastRestartWasMaintenance = false
            lastRestartWasManualFromHealthy = false
            healthySince = now
            consecutiveFailures = 0
            failureTimestamps.removeAll()
            failingSince = nil
            failingStreakHadProcessExit = false
            scheduledRespawnAt = .distantFuture
            phase = .healthy
            lastTransition = now
            effects.append(.emit(recovering ? .recovered : .becameHealthy))
        }

        effects.append(.updateModels)
        return MachineOutput(effects: effects, nextWait: config.probeInterval)
    }

    private mutating func handleFailure(_ reason: DownReason, killNeeded: Bool, now: Date) -> MachineOutput {
        consecutiveFailures += 1
        lastRestartReason = reason.label
        lastDownCategory = reason.category
        lastRestartCategory = reason.category
        if case .crashed = reason { failingStreakHadProcessExit = true }
        healthySince = nil

        // Record the failure in the sliding crash loop window.
        failureTimestamps.append(now)
        pruneFailureWindow(now: now)

        var effects: [MachineEffect] = [.emit(.down(reason))]
        if killNeeded {
            effects.append(.kill)
        }

        if failureTimestamps.count >= config.crashLoopThreshold {
            // Crash loop: stop thrashing, retry slowly, keep probing.
            let firstEntry = (failingSince == nil)
            if firstEntry {
                failingSince = now
                effects.append(.emit(.enteredFailing(
                    restartsInWindow: failureTimestamps.count,
                    window: config.crashLoopWindow
                )))
            }
            phase = .failing
            scheduledRespawnAt = now.addingTimeInterval(config.failingProbeInterval)
            lastTransition = now
            return MachineOutput(effects: effects, nextWait: config.failingProbeInterval)
        }

        // Normal recovery: back off, then respawn. Reaching here from failing
        // means the earlier failures aged out of the crash loop window, so the
        // failing marker clears with the phase.
        let backoff = config.backoff(forConsecutiveFailure: consecutiveFailures)
        phase = .down
        failingSince = nil
        scheduledRespawnAt = now.addingTimeInterval(backoff)
        lastTransition = now
        effects.append(.emit(.restartScheduled(attempt: consecutiveFailures, backoff: backoff)))
        return MachineOutput(effects: effects, nextWait: backoff)
    }

    private mutating func pruneFailureWindow(now: Date) {
        let cutoff = now.addingTimeInterval(-config.crashLoopWindow)
        failureTimestamps.removeAll { $0 < cutoff }
    }

    private mutating func resetCounters() {
        consecutiveFailures = 0
        restartCount = 0
        failureTimestamps.removeAll()
        failingSince = nil
        failingStreakHadProcessExit = false
        healthySince = nil
        scheduledRespawnAt = .distantFuture
        lastRestartReason = nil
        lastDownCategory = nil
        lastRestartCategory = nil
        lastRestartWasMaintenance = false
        lastRestartWasManualFromHealthy = false
    }
}
