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
    /// Restart a healthy managed runner whose resident size crosses this
    /// ceiling, catching the RSS-creep slow death before it becomes a wedge.
    /// Zero disables the watchdog.
    private let memoryLimitBytes: Int64
    /// OPT-IN PRIVACY TRADE (alertsIncludeLogTail): append a sanitized tail of
    /// the runner's recent stderr to down and failing alerts. Off by default;
    /// log lines are runner content and alerts leave the box.
    private let includeLogTail: Bool
    /// The most recent captured stderr from a managed probe, so a down or
    /// failing alert can carry it when the flag above is on.
    private var lastStderrTail: [String] = []
    /// How long a routine restart (scheduled maintenance, a binary upgrade) may
    /// wait for in-flight work to finish before proceeding anyway. Zero restarts
    /// immediately, as before. Failure restarts never wait: the runner is down.
    private let drainSeconds: TimeInterval
    /// Connections currently open through the metrics proxy, when it is
    /// enabled; nil means in-flight work is not observable and drain is a no-op.
    private let inFlight: (@Sendable () -> Int)?
    /// The point at which an ongoing drain gives up and restarts anyway.
    private var drainDeadline: Date?

    private var machine: SupervisorMachine
    private var currentHandle: ProcessHandleID?
    /// The runner binary's fingerprint at the last spawn, to notice an upgrade.
    private var spawnedBinaryFingerprint: String?
    private var currentModels: [ResidentModel] = []
    private var current: SupervisorState = SupervisorState()
    private var lastSpawnError: String?
    /// When the deep probe last ran or was deliberately deferred, so success,
    /// busy work, and ambiguous failures all respect the slower deep cadence.
    /// Reset at each spawn so a fresh runner is deep-probed once it is
    /// shallow-ready.
    private var lastDeepProbeAt: Date?
    /// Deep inference is intentionally more conservative than shallow
    /// readiness. A queued request and a wedged request can both time out, so a
    /// single ambiguous miss must never kill a serving runner. Failures are
    /// paced at the configured deep interval and require confirmation.
    private var consecutiveDeepProbeFailures = 0
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
    /// When the current uninterrupted busy streak began. A genuinely busy
    /// server works through its queue; a 503 that never ends is a wedge
    /// wearing a busy suit, and past `busyTimeout` it is treated as one.
    private var busySince: Date?
    /// How long uninterrupted busy is believed before it is escalated to
    /// wedged. Without this, a permanently-503 runner would never restart.
    private let busyTimeout: TimeInterval
    /// When the deep probe last failed, surfaced in status and metrics.
    private var lastDeepProbeFailedAt: Date?
    /// The models resident before the most recent teardown, captured at the kill
    /// or down transition so a warm-up after recovery can restore them.
    private var modelsToRestore: [String] = []
    /// Set when the last failure was one reloading the same models would likely
    /// reproduce: an out-of-memory kill, or a crash that landed right after a
    /// warm-up we started. Warm-up is skipped for that recovery, so Hearth does
    /// not re-crash the GPU with a model too big for it.
    private var suppressWarmupAfterCrash = false
    /// When the last warm-up began, to blame a crash that lands soon after on
    /// the warm-up load itself (the OOM classifier is a heuristic and can miss).
    private var lastWarmupStartedAt: Date?
    /// Remembers which models were resident at fit-related crashes, to call out
    /// a model that keeps running the Mac out of memory (proactive guidance, not
    /// just reactive recovery). Windowed, so a model un-flags once it stops.
    private var modelFit: ModelFitLedger
    /// Models already alerted about this streak, so a single crossing pushes one
    /// alert, not one per repeat. Reconciled with the flagged set so a model that
    /// ages out and later re-offends alerts again.
    private var alertedOversizedModels: Set<String> = []
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
                warmModels: Bool = false,
                memoryLimitBytes: Int64 = 0,
                drainSeconds: TimeInterval = 0,
                inFlight: (@Sendable () -> Int)? = nil,
                includeLogTail: Bool = false,
                busyTimeout: TimeInterval = 600,
                modelFitThreshold: Int = 2,
                modelFitWindow: TimeInterval = 1800) {
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
        self.memoryLimitBytes = memoryLimitBytes
        self.drainSeconds = drainSeconds
        self.inFlight = inFlight
        self.includeLogTail = includeLogTail
        self.busyTimeout = busyTimeout
        self.modelFit = ModelFitLedger(threshold: modelFitThreshold, window: modelFitWindow)
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
        suppressWarmupAfterCrash = false
        lastWarmupStartedAt = nil
        consecutiveDeepProbeFailures = 0
        let output = machine.start(now: clock.now)
        await apply(output, models: nil)
        nudgeLoop()
    }

    /// Stop supervising: kill the child and release power immediately.
    public func stop() async {
        controlGeneration &+= 1
        busySince = nil
        drainDeadline = nil
        consecutiveDeepProbeFailures = 0
        let output = machine.stop(now: clock.now)
        await apply(output, models: nil)
        nudgeLoop()
    }

    /// Restart now by request. Does not count as a crash.
    public func restart() async {
        controlGeneration &+= 1
        busySince = nil
        drainDeadline = nil
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
                // Inherits the actor, so expireSleep is a plain same-actor call
                // once the (suspending) clock sleep returns.
                try? await self.clock.sleep(seconds: seconds)
                self.expireSleep(generation)
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
            var report = await probe(now: now)
            // stop() or restart() may have interleaved during the probe await; a
            // stale observation must not resurrect a stopped machine, and the
            // old child's "serving" must not mark the fresh child healthy before
            // it has been probed (skipping startup grace and firing a spurious
            // recovery). Re-step immediately instead.
            if machine.phase == .stopped || generation != controlGeneration { return 0 }
            // Busy is believed, but not forever: a 503 streak past the timeout
            // is escalated to wedged, or a permanently-busy wedge would never
            // restart. Any non-busy answer resets the streak.
            if report.readiness == .busy {
                if busySince == nil { busySince = now }
                if let since = busySince, now.timeIntervalSince(since) >= busyTimeout {
                    report.readiness = .timedOut
                    busySince = nil
                }
            } else {
                busySince = nil
            }
            runnerBusy = report.readiness == .busy
            if !report.recentStderr.isEmpty {
                lastStderrTail = report.recentStderr
            }
            let output = machine.observe(report, now: now)
            // A busy probe carries no model list (the fetch would queue behind
            // the very work making it busy); keep the current one.
            await apply(output, models: runnerBusy ? nil : report.models)
            // The opt-in memory watchdog: Ollama's documented slow death is RSS
            // creep, then growing latency, then a wedge; a readiness probe only
            // catches the end. Restarting at a resident-size ceiling catches it
            // first (pm2's max_memory_restart, translated to unified memory).
            if managed, machine.phase == .healthy, memoryLimitBytes > 0,
               let handle = currentHandle,
               let resident = processes.residentBytes(handle), resident > memoryLimitBytes {
                let output = machine.memoryLimitRestart(
                    residentBytes: resident, limitBytes: memoryLimitBytes, now: now)
                await apply(output, models: nil)
                return output.nextWait
            }
            // Proactive maintenance restart, both off unless configured: cycle a
            // long-healthy managed runner to clear the memory creep and VRAM
            // fragmentation that degrade a 24/7 runner, or adopt a runner binary
            // that was upgraded on disk rather than serving the old one forever.
            let maintenanceDue = policy.maintenanceRestartDue(
                healthySince: machine.healthySince, now: now, minuteOfDay: Self.minuteOfDay(of: now))
            let upgraded = binaryWasUpgraded()
            if managed, machine.phase == .healthy, maintenanceDue || upgraded {
                // A routine restart can afford manners: with the metrics proxy
                // watching traffic, wait for in-flight generations to finish
                // (bounded by drainSeconds) instead of cutting one off mid-token.
                if shouldDrainBeforeRoutineRestart(now: now) {
                    return policy.probeInterval
                }
                // A binary change is the more specific reason when both apply.
                let category = upgraded ? "binary-upgrade" : "maintenance"
                let maintenance = machine.maintenanceRestart(now: now, category: category)
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
            let fetchedModels = readiness == .ready ? await fetchModels() : nil
            let models = fetchedModels ?? currentModels
            if readiness == .ready {
                readiness = await readinessAfterDeepProbe(
                    now: now,
                    residentModels: models,
                    residencyIsCurrent: fetchedModels != nil)
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
        var models = currentModels
        let fetchedModels = readiness == .ready ? await fetchModels() : nil
        if let fetched = fetchedModels {
            models = fetched
        }
        if readiness == .ready {
            readiness = await readinessAfterDeepProbe(
                now: now,
                residentModels: models,
                residencyIsCurrent: fetchedModels != nil)
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

    private enum DeepProbeVerdict {
        case serving
        case busy
        case unconfirmedFailure
        case confirmedFailure
    }

    /// Translate the inference-specific result back into the existing readiness
    /// vocabulary. A first ambiguous miss remains serving while Hearth verifies
    /// it; a queue-full response or observed client traffic is busy; only a
    /// confirmed miss becomes a destructive wedge signal.
    private func readinessAfterDeepProbe(
        now: Date,
        residentModels: [ResidentModel],
        residencyIsCurrent: Bool
    ) async -> Readiness {
        switch await deepProbeVerdict(
            now: now,
            residentModels: residentModels,
            residencyIsCurrent: residencyIsCurrent) {
        case .serving, .unconfirmedFailure:
            return .ready
        case .busy:
            return .busy
        case .confirmedFailure:
            return .timedOut
        }
    }

    /// The optional deep readiness probe, run on its own slower cadence. Deep
    /// timeouts are ambiguous because a legitimate long generation may occupy
    /// the queue. Hearth therefore refuses to probe while proxy-observed client
    /// work is active, treats HTTP 503 as busy, and requires two failures spaced
    /// by the configured deep interval before recovery may become destructive.
    private func deepProbeVerdict(
        now: Date,
        residentModels: [ResidentModel],
        residencyIsCurrent: Bool
    ) async -> DeepProbeVerdict {
        guard let deep = deepProbe else { return .serving }
        if let last = lastDeepProbeAt, now.timeIntervalSince(last) < deep.interval {
            return .serving
        }
        if let inFlight, inFlight() > 0 {
            consecutiveDeepProbeFailures = 0
            lastDeepProbeAt = now
            return .busy
        }
        let wasResident = residentModels.contains { $0.name == deep.model }
        guard let request = runner.deepReadinessRequest(
            model: deep.model,
            unloadAfter: residencyIsCurrent && !wasResident) else {
            consecutiveDeepProbeFailures = 0
            return .serving
        }
        let outcome = await http.post(request.url, body: request.body, timeout: deep.timeout)
        switch outcome {
        case .ok:
            lastDeepProbeAt = now
            consecutiveDeepProbeFailures = 0
            return .serving
        case .http(status: 503, body: _):
            lastDeepProbeAt = now
            consecutiveDeepProbeFailures = 0
            return .busy
        default:
            lastDeepProbeFailedAt = now
            consecutiveDeepProbeFailures += 1
            if consecutiveDeepProbeFailures >= 2 {
                // Do not cache a confirmed failure. Attached mode has no spawn
                // to clear the timestamp, so every recovery attempt must prove
                // inference again rather than passing on cadence alone.
                lastDeepProbeAt = nil
                return .confirmedFailure
            }
            lastDeepProbeAt = now
            return .unconfirmedFailure
        }
    }

    /// Whether a due routine restart should wait for in-flight work. True while
    /// the proxy reports open connections and the drain budget has not run out;
    /// the deadline is set once per drain so a busy server cannot defer forever.
    private func shouldDrainBeforeRoutineRestart(now: Date) -> Bool {
        guard drainSeconds > 0, let inFlight else { return false }
        guard inFlight() > 0 else {
            drainDeadline = nil
            return false
        }
        if let deadline = drainDeadline {
            if now >= deadline {
                drainDeadline = nil
                return false
            }
            return true
        }
        drainDeadline = now.addingTimeInterval(drainSeconds)
        return true
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
                if let models {
                    let inventoryChanged = !sameResidentModelInventory(models, currentModels)
                    // Keep expiry metadata current for status surfaces, but only
                    // spend an event-log line when the actual resident set or
                    // footprint changed.
                    currentModels = models
                    if inventoryChanged {
                        eventContinuation.yield(.modelsUpdated(models))
                    }
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
        consecutiveDeepProbeFailures = 0
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
        var followUps: [SupervisorEvent] = []
        switch event {
        case .down(let reason):
            // A crash can land without a kill effect; snapshot here too so the
            // warm-up knows what was resident before the failure.
            if !currentModels.isEmpty {
                modelsToRestore = currentModels.map(\.name)
            }
            // Would reloading these models just reproduce the crash? Two signals:
            // the exit was classified out-of-memory, or a crash landed within the
            // warm-up window of a warm-up we started (the heuristic OOM classifier
            // can miss, so the timing is a second, classifier-independent guard).
            let oom = reason == .crashed(.outOfMemory)
            let crashedSoonAfterWarmup = reason.isCrash
                && (lastWarmupStartedAt.map { clock.now.timeIntervalSince($0) < Self.warmupTimeout } ?? false)
            if oom || crashedSoonAfterWarmup {
                suppressWarmupAfterCrash = true
                // The same signal drives the model-fit ledger: a fit-related crash
                // with models resident. When one crosses the threshold, say so.
                if !modelsToRestore.isEmpty {
                    modelFit.record(models: modelsToRestore, at: clock.now)
                    for model in modelFit.flaggedModels(now: clock.now) where !alertedOversizedModels.contains(model) {
                        alertedOversizedModels.insert(model)
                        followUps.append(.modelLikelyTooLarge(model: model))
                    }
                }
            }
        case .recovered, .becameHealthy:
            startWarmupIfNeeded()
        default:
            break
        }
        eventContinuation.yield(event)
        if event.isNotable, let notification = Self.notification(
            for: event,
            logTail: includeLogTail ? Self.sanitizedLogTail(lastStderrTail) : []) {
            await notifier.notify(notification)
        }
        // Emit any derived events (a model crossing the too-large threshold) after
        // the triggering event, so the log reads down, then the guidance.
        for followUp in followUps {
            await handleEvent(followUp)
        }
    }

    /// The tail the opt-in flag appends to an alert: a few lines, bounded in
    /// length, control characters stripped, so a hostile or chatty runner can
    /// neither bloat the alert nor smuggle terminal escapes into it.
    static func sanitizedLogTail(_ lines: [String], maxLines: Int = 5, maxLineLength: Int = 200) -> [String] {
        lines.suffix(maxLines).map { line in
            let cleaned = String(String.UnicodeScalarView(
                line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            guard cleaned.count > maxLineLength else { return cleaned }
            return String(cleaned.prefix(maxLineLength)) + "\u{2026}"
        }
    }

    /// Load the models that were resident before the restart, off the loop (a
    /// cold load takes minutes and supervision must keep probing). Each model
    /// gets a one-token generation, the same request the deep probe uses; the
    /// runner's own keep-alive policy then owns residency, as always.
    private func startWarmupIfNeeded() {
        guard warmModels, !modelsToRestore.isEmpty else { return }
        // The runner just crashed loading these very models; reloading them would
        // most likely crash it again. Leave the runner idle-but-alive (the user
        // can switch to a smaller model) and say why, instead of driving a GPU
        // crash loop.
        if suppressWarmupAfterCrash {
            let skipped = modelsToRestore
            modelsToRestore = []
            suppressWarmupAfterCrash = false
            Task { [weak self] in await self?.handleEvent(.warmupSkippedAfterCrash(models: skipped)) }
            return
        }
        let requests: [(String, DeepProbeRequest)] = modelsToRestore.compactMap { model in
            runner.deepReadinessRequest(model: model).map { (model, $0) }
        }
        modelsToRestore = []
        guard !requests.isEmpty else { return }
        lastWarmupStartedAt = clock.now
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
        // Models the ledger currently considers too large. Reconcile the alerted
        // set so a model that ages out of the window can alert again if it
        // re-offends, and a model that stopped crashing drops off the status.
        let oversized = modelFit.flaggedModels(now: clock.now)
        alertedOversizedModels.formIntersection(oversized)
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
            lastRestartCategory: machine.lastRestartCategory,
            deepProbeConfigured: deepProbe != nil,
            deepProbeLastFailedAt: lastDeepProbeFailedAt,
            oversizedModels: oversized
        )
        current = state
        stateContinuation.yield(state)
    }

    /// Map a notable event onto a notification. Notifications fire on down,
    /// recovered, and failing. Each body ends with where to look next; a phone
    /// alert with no next step just worries the reader. `logTail` is non-empty
    /// only when the user opted into alertsIncludeLogTail; it is appended to
    /// the down and failing bodies, the two alerts whose "why" is in the log.
    static func notification(for event: SupervisorEvent, logTail: [String] = []) -> HearthNotification? {
        switch event {
        case .down(let reason):
            return HearthNotification(
                level: .warning,
                title: "Runner down",
                body: appendLogTail("The runner stopped serving: \(reason.label). Details and recent activity: the Hearth menu, or `hearth status` in a terminal.", logTail),
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
                body: appendLogTail("The runner keeps failing: \(count) times in \(Int(window))s. Hearth is still retrying, more slowly. The runner log shows why (Open Logs in the Hearth menu, or `hearth logs`); `hearth doctor` checks the setup.", logTail),
                event: event
            )
        case .warmupFinished(let missing) where !missing.isEmpty:
            return HearthNotification(
                level: .warning,
                title: "Models not restored",
                body: "After the restart, \(missing.joined(separator: ", ")) could not be loaded again; the next request will pay the cold start. The runner log shows why (`hearth logs`).",
                event: event
            )
        case .memoryLimitExceeded(let resident, let limit):
            return HearthNotification(
                level: .warning,
                title: "Memory limit restart",
                body: "The runner reached \(StatusText.byteString(resident)) resident, over the \(StatusText.byteString(limit)) limit, and was restarted before it could wedge. If this repeats quickly, the limit may be too small for the loaded models.",
                event: event
            )
        case .warmupSkippedAfterCrash(let models):
            return HearthNotification(
                level: .warning,
                title: "Models not reloaded",
                body: "The runner crashed loading \(models.joined(separator: ", ")), so Hearth did not reload it after the restart: doing so would likely crash the GPU again. Load a smaller model, or lower the context size, for this machine's memory.",
                event: event
            )
        case .modelLikelyTooLarge(let model):
            return HearthNotification(
                level: .warning,
                title: "Model likely too large",
                body: "\(model) has repeatedly run this Mac out of memory as it loaded. It likely does not fit in this machine's unified memory. Use a smaller model or a lower context size; a quantized variant often fits.",
                event: event
            )
        default:
            return nil
        }
    }

    private static func appendLogTail(_ body: String, _ tail: [String]) -> String {
        guard !tail.isEmpty else { return body }
        return body + "\n\nRunner log tail (alertsIncludeLogTail):\n" + tail.joined(separator: "\n")
    }
}
