// SPDX-License-Identifier: MIT

import Foundation

/// The supervision loop, on a background actor. It owns the pure
/// `SupervisorMachine` and translates the machine's effects into real I/O
/// through the injected protocols. It probes health, feeds observations to the
/// machine, runs the effects, and publishes a typed state and event stream that
/// the UI observes. It never drives the UI directly.
public actor SupervisorEngine {
    private let clock: SupervisorClock
    private let processes: ProcessControlling
    private let http: HTTPClient
    private let runner: Runner
    private let power: PowerManaging
    private let notifier: Notifier
    private let policy: RestartPolicyConfig
    /// Managed mode spawns and owns the runner. Attached mode (managed == false)
    /// only monitors an already running one: it probes readiness, holds power,
    /// and notifies on transitions, but never spawns or kills a process it does
    /// not own.
    private let managed: Bool

    private var machine: SupervisorMachine
    private var currentHandle: ProcessHandleID?
    /// The runner binary's fingerprint at the last spawn, to notice an upgrade.
    private var spawnedBinaryFingerprint: String?
    private var currentModels: [ResidentModel] = []
    private var current: SupervisorState = SupervisorState()
    private var lastSpawnError: String?
    private var looping = false

    /// Continuous published state. One consumer; the app reads `snapshot()` for
    /// the current value before subscribing.
    public nonisolated let states: AsyncStream<SupervisorState>
    /// Discrete events.
    public nonisolated let events: AsyncStream<SupervisorEvent>
    private let stateContinuation: AsyncStream<SupervisorState>.Continuation
    private let eventContinuation: AsyncStream<SupervisorEvent>.Continuation

    public init(clock: SupervisorClock,
                processes: ProcessControlling,
                http: HTTPClient,
                runner: Runner,
                power: PowerManaging,
                notifier: Notifier,
                policy: RestartPolicyConfig,
                managed: Bool = true) {
        self.clock = clock
        self.processes = processes
        self.http = http
        self.runner = runner
        self.power = power
        self.notifier = notifier
        self.policy = policy
        self.managed = managed
        self.machine = SupervisorMachine(config: policy)

        let (stateStream, stateCont) = AsyncStream.makeStream(of: SupervisorState.self)
        let (eventStream, eventCont) = AsyncStream.makeStream(of: SupervisorEvent.self)
        self.states = stateStream
        self.events = eventStream
        self.stateContinuation = stateCont
        self.eventContinuation = eventCont
    }

    // MARK: - Public control surface

    /// The latest published state. Read once before subscribing to `states`.
    public func snapshot() -> SupervisorState { current }

    /// Begin supervising. No effect if already supervising.
    public func start() async {
        guard machine.phase == .stopped else { return }
        let output = machine.start(now: clock.now)
        await apply(output, models: nil)
    }

    /// Stop supervising: kill the child and release power immediately.
    public func stop() async {
        let output = machine.stop(now: clock.now)
        await apply(output, models: nil)
    }

    /// Restart now by request. Does not count as a crash.
    public func restart() async {
        let output = machine.userRestart(now: clock.now)
        await apply(output, models: nil)
    }

    /// Run the supervision loop until stopped. Safe to call once per session;
    /// re entry is a no op while a loop is already running.
    public func runLoop() async {
        guard !looping else { return }
        looping = true
        defer { looping = false }
        while machine.phase != .stopped {
            let wait = await stepOnce()
            if machine.phase == .stopped { break }
            if wait > 0 {
                try? await clock.sleep(seconds: wait)
            }
        }
    }

    /// Perform exactly one iteration of the loop and return how long to wait
    /// before the next one. Exposed so tests can drive the engine deterministically
    /// with a manual clock, advancing time instead of sleeping.
    public func stepOnce() async -> TimeInterval {
        let now = clock.now
        switch machine.phase {
        case .stopped:
            return 0
        case .starting, .restarting, .healthy:
            let report = await probe(now: now)
            // stop() may have interleaved during the probe await; do not let a
            // stale observation resurrect a stopped machine.
            if machine.phase == .stopped { return 0 }
            let output = machine.observe(report, now: now)
            await apply(output, models: report.models)
            // Proactive maintenance restart, both off unless configured: cycle a
            // long-healthy managed runner to clear the memory creep and VRAM
            // fragmentation that degrade a 24/7 runner, or adopt a runner binary
            // that was upgraded on disk rather than serving the old one forever.
            if managed, machine.phase == .healthy,
               policy.maintenanceRestartDue(healthySince: machine.healthySince, now: now) || binaryWasUpgraded() {
                let maintenance = machine.maintenanceRestart(now: now)
                await apply(maintenance, models: nil)
                return maintenance.nextWait
            }
            return output.nextWait
        case .down, .failing:
            if machine.respawnDue(now: now) {
                let output = machine.respawnNow(now: now)
                await apply(output, models: nil)
                return output.nextWait
            }
            return max(0, machine.scheduledRespawnAt.timeIntervalSince(now))
        }
    }

    // MARK: - Probing

    private func probe(now: Date) async -> HealthReport {
        if !managed {
            // Attached mode: there is no child to inspect. Readiness is the whole
            // health signal. When unreachable, report not alive so the machine
            // treats it as a failure without trying to kill a process we do not
            // own (the kill effect is skipped anyway).
            let outcome = await http.get(runner.readinessEndpoint, timeout: policy.probeTimeout)
            let readiness = Readiness.from(outcome)
            guard readiness == .ready else {
                return HealthReport(isAlive: false, readiness: readiness, exitReason: .unknown)
            }
            let models = await fetchModels() ?? currentModels
            return HealthReport(isAlive: true, readiness: .ready, exitReason: .running, models: models)
        }

        guard let handle = currentHandle else {
            // No child (spawn failed or never spawned): treat as dead.
            return HealthReport(isAlive: false, readiness: .unknown, exitReason: .unknown)
        }
        let status = processes.status(handle)
        if !status.isAlive {
            let reason = runner.classifyExit(status.exit, stderr: status.recentStderr)
            return HealthReport(isAlive: false,
                                readiness: .unknown,
                                exitReason: reason,
                                recentStderr: status.recentStderr)
        }
        let outcome = await http.get(runner.readinessEndpoint, timeout: policy.probeTimeout)
        let readiness = Readiness.from(outcome)
        var models = currentModels
        if readiness == .ready, let fetched = await fetchModels() {
            models = fetched
        }
        return HealthReport(isAlive: true,
                            readiness: readiness,
                            exitReason: .running,
                            models: models,
                            recentStderr: status.recentStderr)
    }

    private func fetchModels() async -> [ResidentModel]? {
        let outcome = await http.get(runner.modelsEndpoint, timeout: policy.probeTimeout)
        guard case .ok(let data) = outcome else { return nil }
        return try? runner.parseResidentModels(data)
    }

    // MARK: - Effect interpretation

    private func apply(_ output: MachineOutput, models: [ResidentModel]?) async {
        for effect in output.effects {
            switch effect {
            case .spawn:
                // Attached mode never spawns; it monitors a runner it does not own.
                if managed { spawnChild() }
            case .kill:
                if managed { killChild() }
            case .holdPower:
                power.hold()
            case .releasePower:
                power.release()
            case .updateModels:
                if let models, models != currentModels {
                    currentModels = models
                    eventContinuation.yield(.modelsUpdated(models))
                }
            case .emit(let event):
                await handleEvent(event)
            }
        }
        publishState()
    }

    /// Whether the runner binary on disk differs from the one we spawned, when
    /// opted in. Fingerprints that cannot be read (nil) never trigger a restart.
    private func binaryWasUpgraded() -> Bool {
        guard policy.restartOnBinaryChange,
              let spawned = spawnedBinaryFingerprint,
              let current = processes.executableFingerprint(at: runner.processSpec().executableURL)
        else { return false }
        return current != spawned
    }

    private func spawnChild() {
        // Sweep the previous runner tree before starting a new one. A crash or an
        // external kill of the runner can orphan its grandchildren (an Ollama
        // serve leaves a llama-server holding GPU memory); terminating the old
        // handle kills that whole process group so a restart loop cannot stack up
        // leaked runners. Idempotent: terminating an already dead group is a no op.
        if let previous = currentHandle {
            processes.terminate(previous)
        }
        do {
            currentHandle = try processes.spawn(runner.processSpec())
            spawnedBinaryFingerprint = processes.executableFingerprint(at: runner.processSpec().executableURL)
            lastSpawnError = nil
        } catch {
            // A failed spawn funnels into the normal failure path: the next probe
            // sees no live child and treats it as a death.
            currentHandle = nil
            lastSpawnError = String(describing: error)
        }
    }

    private func killChild() {
        if let handle = currentHandle {
            processes.terminate(handle)
        }
    }

    private func handleEvent(_ event: SupervisorEvent) async {
        eventContinuation.yield(event)
        if event.isNotable, let notification = Self.notification(for: event) {
            await notifier.notify(notification)
        }
    }

    private func publishState() {
        let pendingRetry = (machine.phase == .down || machine.phase == .failing)
            ? machine.scheduledRespawnAt
            : nil
        let state = SupervisorState(
            phase: machine.phase,
            residentModels: currentModels,
            healthySince: machine.healthySince,
            lastRestartReason: machine.lastRestartReason,
            restartCount: machine.restartCount,
            consecutiveFailures: machine.consecutiveFailures,
            failingSince: machine.failingSince,
            nextRetryAt: pendingRetry,
            lastTransition: machine.lastTransition
        )
        current = state
        stateContinuation.yield(state)
    }

    /// Map a notable event onto a notification. Notifications fire on down,
    /// recovered, and failing.
    static func notification(for event: SupervisorEvent) -> HearthNotification? {
        switch event {
        case .down(let reason):
            return HearthNotification(
                level: .warning,
                title: "Runner down",
                body: "The runner stopped serving: \(reason.label).",
                event: event
            )
        case .recovered:
            return HearthNotification(
                level: .info,
                title: "Runner recovered",
                body: "The runner is healthy again.",
                event: event
            )
        case .enteredFailing(let count, let window):
            return HearthNotification(
                level: .critical,
                title: "Runner failing",
                body: "Crash loop: \(count) failures within \(Int(window))s. Backing off and retrying slowly.",
                event: event
            )
        default:
            return nil
        }
    }
}
