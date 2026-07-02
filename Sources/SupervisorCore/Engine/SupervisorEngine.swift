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
    /// The optional deep readiness probe (a periodic real inference), or nil when
    /// only the shallow `/api/version` probe is used.
    private let deepProbe: DeepProbeConfig?
    /// When true, the models that were resident before a restart are loaded
    /// again (a one-token generation each) once the runner is healthy, so
    /// recovery does not hand the next client a multi-gigabyte cold start.
    private let warmModels: Bool

    private var machine: SupervisorMachine
    private var currentHandle: ProcessHandleID?
    /// The runner binary's fingerprint at the last spawn, to notice an upgrade.
    private var spawnedBinaryFingerprint: String?
    private var currentModels: [ResidentModel] = []
    private var current: SupervisorState = SupervisorState()
    private var lastSpawnError: String?
    /// When the deep probe last passed, so it runs on its own slower cadence.
    /// Only a pass is recorded; a failure clears this so a wedged runner keeps
    /// failing every cycle. Reset at each spawn so a fresh runner is deep-probed
    /// once it is shallow-ready.
    private var lastDeepProbeAt: Date?
    private var looping = false
    /// Bumped by every external control action (start, stop, restart), so a
    /// probe that was in flight across the actor's await can tell its report
    /// belongs to the previous child and must not be applied to the fresh one.
    private var controlGeneration = 0
    /// The continuation parked by the loop's interruptible wait, resumed early
    /// by a control action so a user restart is probed immediately instead of
    /// silently sleeping out the remaining backoff.
    private var loopWake: CheckedContinuation<Void, Never>?
    /// Ties each timeout task to its own wait, so a timer that outlives a nudge
    /// cannot resume the loop's NEXT wait early.
    private var sleepGeneration = 0
    /// Whether the last probe answered busy (a full queue), for the status line.
    private var runnerBusy = false
    /// When the deep probe last failed, surfaced in status and metrics.
    private var lastDeepProbeFailedAt: Date?
    /// The models resident before the most recent teardown, captured at the kill
    /// or down transition so a warm-up after recovery can restore them.
    private var modelsToRestore: [String] = []
    /// A cold model load is legitimately slow; give each warm-up request minutes.
    static let warmupTimeout: TimeInterval = 180

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
                managed: Bool = true,
                deepProbe: DeepProbeConfig? = nil,
                warmModels: Bool = false) {
        self.clock = clock
        self.processes = processes
        self.http = http
        self.runner = runner
        self.power = power
        self.notifier = notifier
        self.policy = policy
        self.managed = managed
        self.deepProbe = deepProbe
        self.warmModels = warmModels
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
        controlGeneration &+= 1
        // A fresh session warms nothing: whatever was resident before an
        // explicit stop is stale intent, not a recovery to hide.
        modelsToRestore = []
        let output = machine.start(now: clock.now)
        await apply(output, models: nil)
        nudgeLoop()
    }

    /// Stop supervising: kill the child and release power immediately.
    public func stop() async {
        controlGeneration &+= 1
        let output = machine.stop(now: clock.now)
        await apply(output, models: nil)
        nudgeLoop()
    }

    /// Restart now by request. Does not count as a crash.
    public func restart() async {
        controlGeneration &+= 1
        let output = machine.userRestart(now: clock.now)
        await apply(output, models: nil)
        nudgeLoop()
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
                await interruptibleSleep(seconds: wait)
            }
        }
    }

    /// Sleep that a control action can cut short. A plain clock.sleep here made
    /// a user restart during backoff invisible: the fresh child was spawned but
    /// the loop kept sleeping out the remaining wait (up to maxBackoff, or the
    /// failing retry interval), so it went unprobed and no recovery was
    /// announced for minutes.
    private func interruptibleSleep(seconds: TimeInterval) async {
        sleepGeneration &+= 1
        let generation = sleepGeneration
        await withCheckedContinuation { continuation in
            loopWake = continuation
            Task {
                try? await self.clock.sleep(seconds: seconds)
                await self.expireSleep(generation)
            }
        }
    }

    private func expireSleep(_ generation: Int) {
        // A stale timer (its wait was already nudged awake) must not resume the
        // loop's next wait early.
        guard generation == sleepGeneration, let continuation = loopWake else { return }
        loopWake = nil
        continuation.resume()
    }

    private func nudgeLoop() {
        guard let continuation = loopWake else { return }
        loopWake = nil
        continuation.resume()
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
            let generation = controlGeneration
            let report = await probe(now: now)
            // stop() or restart() may have interleaved during the probe await; a
            // stale observation must not resurrect a stopped machine, and the
            // old child's "serving" must not mark the fresh child healthy before
            // it has been probed (skipping startup grace and firing a spurious
            // recovery). Re-step immediately instead.
            if machine.phase == .stopped || generation != controlGeneration { return 0 }
            runnerBusy = report.readiness == .busy
            let output = machine.observe(report, now: now)
            // A busy probe carries no model list (the fetch would queue behind
            // the very work making it busy); keep the current one.
            await apply(output, models: runnerBusy ? nil : report.models)
            // Proactive maintenance restart, both off unless configured: cycle a
            // long-healthy managed runner to clear the memory creep and VRAM
            // fragmentation that degrade a 24/7 runner, or adopt a runner binary
            // that was upgraded on disk rather than serving the old one forever.
            if managed, machine.phase == .healthy,
               policy.maintenanceRestartDue(healthySince: machine.healthySince, now: now,
                                            minuteOfDay: Self.minuteOfDay(of: now)) || binaryWasUpgraded() {
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
            var readiness = Readiness.from(outcome)
            if readiness == .ready, !(await deepProbePassed(now: now)) {
                readiness = .timedOut   // the HTTP server answers, but inference is wedged
            }
            guard readiness == .ready else {
                // Busy (a full queue) is serving: the runner is doing its job.
                // A hang (or failed deep probe) means something is still there
                // and stuck: report it alive so the down reason reads as wedged
                // rather than an invented exit. Kill and spawn are skipped in
                // attached mode either way. Anything else (refused, error) means
                // the runner is gone as far as a watcher can tell.
                if readiness == .busy || readiness == .timedOut {
                    return HealthReport(isAlive: true, readiness: readiness, exitReason: .running)
                }
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
        var readiness = Readiness.from(outcome)
        if readiness == .ready, !(await deepProbePassed(now: now)) {
            readiness = .timedOut   // the HTTP server answers, but inference is wedged
        }
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

    /// The optional deep readiness probe, run on its own slower cadence. Returns true
    /// when it is not enabled, not yet due, or it passed; false when a real inference
    /// request fails or times out, which means the model runner is wedged even though
    /// the shallow endpoint still answers.
    private func deepProbePassed(now: Date) async -> Bool {
        guard let deep = deepProbe else { return true }
        if let last = lastDeepProbeAt, now.timeIntervalSince(last) < deep.interval { return true }
        guard let request = runner.deepReadinessRequest(model: deep.model) else { return true }
        if case .ok = await http.post(request.url, body: request.body, timeout: deep.timeout) {
            // Only a pass is cached, so a healthy runner is not deep-probed every
            // cycle. A failure must not suppress the next probe: in attached mode
            // nothing respawns to reset the timestamp, so caching a failure would
            // let the next shallow-ready cycle skip the deep probe and falsely
            // report a still-wedged runner as recovered.
            lastDeepProbeAt = now
            return true
        }
        lastDeepProbeAt = nil
        lastDeepProbeFailedAt = now
        return false
    }

    /// Minutes since local midnight, for the maintenance window check. Uses the
    /// system calendar because the window is a human wall-clock intent.
    private static func minuteOfDay(of date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    // MARK: - Effect interpretation

    private func apply(_ output: MachineOutput, models: [ResidentModel]?) async {
        for effect in output.effects {
            switch effect {
            case .spawn:
                // Attached mode never spawns; it monitors a runner it does not own.
                if managed { spawnChild() }
            case .kill:
                // The teardown is where the resident set is last trustworthy;
                // capture it so the post-recovery warm-up can restore it.
                if !currentModels.isEmpty {
                    modelsToRestore = currentModels.map(\.name)
                }
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
        lastDeepProbeAt = nil   // deep-probe the fresh runner once it is shallow-ready
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
        switch event {
        case .down:
            // A crash can land without a kill effect; snapshot here too so the
            // warm-up knows what was resident before the failure.
            if !currentModels.isEmpty {
                modelsToRestore = currentModels.map(\.name)
            }
        case .recovered, .becameHealthy:
            startWarmupIfNeeded()
        default:
            break
        }
        eventContinuation.yield(event)
        if event.isNotable, let notification = Self.notification(for: event) {
            await notifier.notify(notification)
        }
    }

    /// Load the models that were resident before the restart, off the loop (a
    /// cold load takes minutes and supervision must keep probing). Each model
    /// gets a one-token generation, the same request the deep probe uses; the
    /// runner's own keep-alive policy then owns residency, as always.
    private func startWarmupIfNeeded() {
        guard warmModels, !modelsToRestore.isEmpty else { return }
        let requests: [(String, DeepProbeRequest)] = modelsToRestore.compactMap { model in
            runner.deepReadinessRequest(model: model).map { (model, $0) }
        }
        modelsToRestore = []
        guard !requests.isEmpty else { return }
        let http = self.http
        Task.detached { [weak self] in
            var missing: [String] = []
            for (model, request) in requests {
                let outcome = await http.post(request.url, body: request.body, timeout: Self.warmupTimeout)
                if case .ok = outcome {} else { missing.append(model) }
            }
            await self?.warmupFinished(missing: missing)
        }
    }

    private func warmupFinished(missing: [String]) async {
        await handleEvent(.warmupFinished(missing: missing))
    }

    private func publishState() {
        let pendingRetry = (machine.phase == .down || machine.phase == .failing)
            ? machine.scheduledRespawnAt
            : nil
        // A failed spawn (a bad or incompatible binary that posix_spawn rejected)
        // otherwise surfaces only as a generic "down". When the last spawn errored
        // and we are down, say what went wrong instead, so the menu/status/`/status`
        // report the cause rather than a bare phase. lastSpawnError is cleared on the
        // next successful spawn, so a later crash never shows a stale message.
        var reason = machine.lastRestartReason
        if let spawnError = lastSpawnError, machine.phase == .down || machine.phase == .failing {
            reason = "spawn failed: \(spawnError)"
        }
        let state = SupervisorState(
            phase: machine.phase,
            residentModels: currentModels,
            healthySince: machine.healthySince,
            lastRestartReason: reason,
            restartCount: machine.restartCount,
            consecutiveFailures: machine.consecutiveFailures,
            failingSince: machine.failingSince,
            nextRetryAt: pendingRetry,
            lastTransition: machine.lastTransition,
            failingStreakHadProcessExit: machine.failingStreakHadProcessExit,
            busy: runnerBusy && machine.phase == .healthy,
            lastDownCategory: machine.lastDownCategory,
            deepProbeConfigured: deepProbe != nil,
            deepProbeLastFailedAt: lastDeepProbeFailedAt
        )
        current = state
        stateContinuation.yield(state)
    }

    /// Map a notable event onto a notification. Notifications fire on down,
    /// recovered, and failing. Each body ends with where to look next; a phone
    /// alert with no next step just worries the reader.
    static func notification(for event: SupervisorEvent) -> HearthNotification? {
        switch event {
        case .down(let reason):
            return HearthNotification(
                level: .warning,
                title: "Runner down",
                body: "The runner stopped serving: \(reason.label). Details and recent activity: the Hearth menu, or `hearth status` in a terminal.",
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
                body: "The runner keeps failing: \(count) times in \(Int(window))s. Hearth is still retrying, more slowly. The runner log shows why (Open Logs in the Hearth menu, or `hearth logs`); `hearth doctor` checks the setup.",
                event: event
            )
        case .warmupFinished(let missing) where !missing.isEmpty:
            return HearthNotification(
                level: .warning,
                title: "Models not restored",
                body: "After the restart, \(missing.joined(separator: ", ")) could not be loaded again; the next request will pay the cold start. The runner log shows why (`hearth logs`).",
                event: event
            )
        default:
            return nil
        }
    }
}
