// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// End to end checks of the engine driving real effects through fakes. Time is
/// advanced by hand and the loop is pumped with `stepOnce`, so there is no real
/// sleep and no Ollama.
struct EngineTests {
    private struct Harness {
        let engine: SupervisorEngine
        let clock: ManualClock
        let processes: FakeProcessController
        let http: FakeHTTPClient
        let power: FakePowerManager
        let notifier: FakeNotifier
        let runner: OllamaRunner
    }

    private func makeHarness(policy: RestartPolicyConfig = RestartPolicyConfig(startupGrace: 30),
                             deepProbe: DeepProbeConfig? = nil,
                             warmModels: Bool = false,
                             memoryLimitBytes: Int64 = 0,
                             drainSeconds: TimeInterval = 0,
                             inFlight: (@Sendable () -> Int)? = nil) -> Harness {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 0))
        let processes = FakeProcessController()
        let http = FakeHTTPClient()
        let power = FakePowerManager()
        let notifier = FakeNotifier()
        let runner = OllamaRunner(binaryPath: "/x", host: "127.0.0.1", port: 11434)
        let engine = SupervisorEngine(
            clock: clock,
            processes: processes,
            http: http,
            runner: runner,
            power: power,
            notifier: notifier,
            policy: policy,
            deepProbe: deepProbe,
            warmModels: warmModels,
            memoryLimitBytes: memoryLimitBytes,
            drainSeconds: drainSeconds,
            inFlight: inFlight
        )
        return Harness(engine: engine, clock: clock, processes: processes, http: http,
                       power: power, notifier: notifier, runner: runner)
    }

    private func makeServing(_ h: Harness, models: String = #"{"models":[{"name":"llama3:8b","size":42}]}"#) {
        h.http.set(h.runner.readinessEndpoint, .ok(Data(#"{"version":"0.1.0"}"#.utf8)))
        h.http.set(h.runner.modelsEndpoint, .ok(Data(models.utf8)))
    }

    @Test func startSpawnsHoldsPowerAndBecomesHealthy() async {
        let h = makeHarness()
        makeServing(h)

        await h.engine.start()
        #expect(h.processes.spawnCount == 1)
        #expect(h.power.isHeld)
        #expect(await h.engine.snapshot().phase == .starting)

        _ = await h.engine.stepOnce()   // probe -> ready -> healthy

        let state = await h.engine.snapshot()
        #expect(state.phase == .healthy)
        #expect(state.residentModels.map(\.name) == ["llama3:8b"])
        #expect(state.healthySince != nil)
    }

    @Test func restartsWhenTheRunnerBinaryIsUpgraded() async {
        let h = makeHarness(policy: RestartPolicyConfig(startupGrace: 30, restartOnBinaryChange: true))
        makeServing(h)
        await h.engine.start()                       // spawn #1, fingerprint "v1"
        _ = await h.engine.stepOnce()                // -> healthy
        #expect(await h.engine.snapshot().phase == .healthy)
        #expect(h.processes.spawnCount == 1)

        // brew upgrade replaced the binary on disk.
        h.processes.setExecutableFingerprint("v2")
        _ = await h.engine.stepOnce()                // healthy + binary changed -> maintenance restart
        #expect(h.processes.spawnCount == 2)         // respawned to adopt the new binary

        // The respawn recorded "v2", so it does not loop on a now-steady binary.
        _ = await h.engine.stepOnce()                // restarting -> healthy
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 2)
    }

    @Test func doesNotRestartOnBinaryChangeWhenDisabled() async {
        let h = makeHarness()   // restartOnBinaryChange is off by default
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)

        h.processes.setExecutableFingerprint("v2")
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 1)   // no restart when the feature is off
    }

    @Test func externalKillIsDetectedRestartedAndRecoveryNotified() async throws {
        let h = makeHarness()
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)

        // Kill ollama serve out from under the supervisor.
        let handle = try #require(h.processes.lastHandle)
        h.processes.simulateExit(handle, exit: ProcessExit(code: 0, wasSignaled: true, signal: 9), stderr: ["killed"])

        // Next probe detects it within the interval and schedules a restart.
        let wait = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .down)
        let downCount = await h.notifier.received.filter { if case .down? = $0.event { return true }; return false }.count
        #expect(downCount == 1)

        // Backoff elapses; the engine respawns.
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 2)

        // The fresh child is serving; the engine sees healthy and fires Recovered.
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)
        let recoveredCount = await h.notifier.received.filter { $0.event == .recovered }.count
        #expect(recoveredCount == 1)
    }

    @Test func aBusyRunnerStaysHealthyAndIsNotRestarted() async {
        let h = makeHarness()
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)

        // The queue fills: readiness answers 503. That is a server doing its
        // job, not a wedge; restarting it would kill the in-flight work.
        h.http.set(h.runner.readinessEndpoint, .http(status: 503, body: Data()))
        _ = await h.engine.stepOnce()

        let state = await h.engine.snapshot()
        #expect(state.phase == .healthy)
        #expect(state.busy)
        #expect(state.consecutiveFailures == 0)
        #expect(h.processes.spawnCount == 1)

        // The queue drains; busy clears.
        makeServing(h)
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().busy == false)
    }

    @Test func aPermanent503IsEventuallyTreatedAsAWedge() async {
        // Busy is believed, but not forever: a 503 that never ends is a wedge
        // wearing a busy suit, and must still be restarted.
        let h = makeHarness()   // busyTimeout defaults to 600
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)

        h.http.set(h.runner.readinessEndpoint, .http(status: 503, body: Data()))
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().busy)
        #expect(h.processes.spawnCount == 1)

        // Ten minutes of uninterrupted 503: the streak crosses the timeout and
        // the next observation is escalated to wedged, killing and respawning.
        h.clock.advance(by: 601)
        _ = await h.engine.stepOnce()
        let state = await h.engine.snapshot()
        #expect(state.phase != .healthy || h.processes.spawnCount == 2)
        #expect(h.processes.spawnCount >= 1)
        let wedgeSeen = await h.notifier.received.contains { $0.event == .down(.wedged) }
        #expect(wedgeSeen)

        // A brief 503 burst that clears resets the streak: no restart.
        makeServing(h)
        var wait = await h.engine.stepOnce()
        while await h.engine.snapshot().phase != .healthy {
            h.clock.advance(by: wait + 0.01)
            wait = await h.engine.stepOnce()
        }
        let spawnsAfterRecovery = h.processes.spawnCount
        h.http.set(h.runner.readinessEndpoint, .http(status: 503, body: Data()))
        _ = await h.engine.stepOnce()
        h.clock.advance(by: 300)   // half the timeout
        makeServing(h)
        _ = await h.engine.stepOnce()
        h.clock.advance(by: 400)   // streak was reset; no escalation
        h.http.set(h.runner.readinessEndpoint, .http(status: 503, body: Data()))
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == spawnsAfterRecovery)
    }

    /// Poll for work a detached warm-up task does off the loop.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    @Test func warmupReloadsTheResidentModelAfterRecovery() async throws {
        let h = makeHarness(warmModels: true)
        makeServing(h)
        let warmURL = try #require(h.runner.deepReadinessRequest(model: "llama3:8b")).url
        h.http.set(warmURL, .ok(Data("{}".utf8)))

        await h.engine.start()
        _ = await h.engine.stepOnce()   // healthy, llama3:8b resident

        let handle = try #require(h.processes.lastHandle)
        h.processes.simulateExit(handle, exit: ProcessExit(code: 1))
        let wait = await h.engine.stepOnce()          // down; snapshot captured
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()                 // respawn
        _ = await h.engine.stepOnce()                 // healthy -> warm-up fires

        let warmed = await eventually { h.http.postCount(to: warmURL) >= 1 }
        #expect(warmed)
    }

    @Test func warmupFailureNotifiesWhichModelWasNotRestored() async throws {
        let h = makeHarness(warmModels: true)
        makeServing(h)
        let warmURL = try #require(h.runner.deepReadinessRequest(model: "llama3:8b")).url
        h.http.set(warmURL, .timedOut)

        await h.engine.start()
        _ = await h.engine.stepOnce()

        let handle = try #require(h.processes.lastHandle)
        h.processes.simulateExit(handle, exit: ProcessExit(code: 1))
        let wait = await h.engine.stepOnce()
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()
        _ = await h.engine.stepOnce()

        let alerted = await eventually {
            await h.notifier.received.contains { $0.title == "Models not restored" }
        }
        #expect(alerted)
    }

    @Test func warmupIsSkippedAfterAnOutOfMemoryCrash() async throws {
        // The scenario a big model creates: it OOMs the GPU, Hearth restarts,
        // and reloading the same model would just crash it again. Warm-up must
        // not drive that loop.
        let h = makeHarness(warmModels: true)
        makeServing(h)
        let warmURL = try #require(h.runner.deepReadinessRequest(model: "llama3:8b")).url
        h.http.set(warmURL, .ok(Data("{}".utf8)))

        await h.engine.start()
        _ = await h.engine.stepOnce()   // healthy, llama3:8b resident

        // The runner is OOM-killed (a signal plus an out-of-memory stderr).
        let handle = try #require(h.processes.lastHandle)
        h.processes.simulateExit(handle, exit: ProcessExit(code: 0, wasSignaled: true, signal: 9),
                                 stderr: ["ggml_metal: failed to allocate buffer"])
        let wait = await h.engine.stepOnce()   // down, classified out-of-memory
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()          // respawn
        _ = await h.engine.stepOnce()          // healthy -> warm-up decision

        // No reload was attempted, and the user is told why.
        let warmed = await eventually { h.http.postCount(to: warmURL) >= 1 }
        #expect(!warmed)
        let told = await eventually {
            await h.notifier.received.contains { $0.title == "Models not reloaded" }
        }
        #expect(told)
    }

    @Test func warmupResumesAfterACleanRestartFollowingAnOOM() async throws {
        // The suppression is per-recovery: once the runner comes back and later
        // restarts for an unrelated reason, warm-up works again.
        let h = makeHarness(warmModels: true)
        makeServing(h)
        let warmURL = try #require(h.runner.deepReadinessRequest(model: "llama3:8b")).url
        h.http.set(warmURL, .ok(Data("{}".utf8)))
        await h.engine.start()
        _ = await h.engine.stepOnce()

        // OOM crash -> warm-up suppressed this recovery.
        var handle = try #require(h.processes.lastHandle)
        h.processes.simulateExit(handle, exit: ProcessExit(code: 0, wasSignaled: true, signal: 9),
                                 stderr: ["out of memory"])
        var wait = await h.engine.stepOnce()
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()
        _ = await h.engine.stepOnce()
        #expect(h.http.postCount(to: warmURL) == 0)

        // A later, ordinary crash (no OOM signature): warm-up should run.
        handle = try #require(h.processes.lastHandle)
        h.processes.simulateExit(handle, exit: ProcessExit(code: 1))
        wait = await h.engine.stepOnce()
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()
        _ = await h.engine.stepOnce()
        let warmed = await eventually { h.http.postCount(to: warmURL) >= 1 }
        #expect(warmed)
    }

    @Test func warmupIsOffByDefault() async throws {
        let h = makeHarness()   // warmModels defaults to false
        makeServing(h)
        let warmURL = try #require(h.runner.deepReadinessRequest(model: "llama3:8b")).url

        await h.engine.start()
        _ = await h.engine.stepOnce()
        let handle = try #require(h.processes.lastHandle)
        h.processes.simulateExit(handle, exit: ProcessExit(code: 1))
        let wait = await h.engine.stepOnce()
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)

        for _ in 0..<50 { await Task.yield() }
        #expect(h.http.postCount(to: warmURL) == 0)
    }

    @Test func memoryWatchdogRestartsARunnerOverItsLimit() async {
        let limit: Int64 = 1_073_741_824   // 1 GiB
        let h = makeHarness(memoryLimitBytes: limit)
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)
        #expect(h.processes.spawnCount == 1)

        // RSS creeps past the ceiling while the runner still answers probes:
        // the slow death a readiness check alone only catches at the wedge.
        h.processes.setResidentBytes(limit * 2)
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 2)
        let warned = await h.notifier.received.contains { $0.title == "Memory limit restart" }
        #expect(warned)

        // The fresh child is under the limit and comes back quietly, without a
        // spurious recovery push (nothing failed from the user's view).
        h.processes.setResidentBytes(limit / 2)
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)
        let recovered = await h.notifier.received.contains { $0.event == .recovered }
        #expect(!recovered)
    }

    @Test func routineRestartWaitsForInFlightWorkThenProceeds() async {
        final class Traffic: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func set(_ value: Int) { lock.withLock { count = value } }
            func get() -> Int { lock.withLock { count } }
        }
        let traffic = Traffic()
        traffic.set(1)
        let h = makeHarness(
            policy: RestartPolicyConfig(startupGrace: 30, restartOnBinaryChange: true),
            drainSeconds: 60,
            inFlight: { traffic.get() }
        )
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 1)

        // A binary upgrade makes a routine restart due, but a generation is in
        // flight: the restart waits instead of cutting it off mid-token.
        h.processes.setExecutableFingerprint("v2")
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 1)

        // The generation finishes; the deferred restart proceeds.
        traffic.set(0)
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 2)
    }

    @Test func aDrainThatOverstaysItsBudgetRestartsAnyway() async {
        let h = makeHarness(
            policy: RestartPolicyConfig(startupGrace: 30, restartOnBinaryChange: true),
            drainSeconds: 30,
            inFlight: { 5 }   // traffic that never lets up
        )
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        h.processes.setExecutableFingerprint("v2")
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 1)   // deferred

        h.clock.advance(by: 31)
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 2)   // budget spent; proceed anyway
    }

    @Test func memoryWatchdogIsOffByDefault() async {
        let h = makeHarness()
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        h.processes.setResidentBytes(1 << 40)   // absurd RSS, no limit configured
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == 1)
    }

    @Test func wedgedRunnerIsCaughtByReadinessWhilePidIsAlive() async throws {
        let h = makeHarness()
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)

        // Hang the API: the socket accepts but nothing answers. PID stays alive.
        h.http.set(h.runner.readinessEndpoint, .timedOut)
        let handle = try #require(h.processes.lastHandle)
        #expect(h.processes.isAlive(handle), "precondition: the process is still alive")

        _ = await h.engine.stepOnce()

        #expect(await h.engine.snapshot().phase == .down)
        // The wedged process was killed so a healthy one can take its place.
        #expect(h.processes.terminateCount >= 1)
        let wedgeCount = await h.notifier.received.filter { $0.event == .down(.wedged) }.count
        #expect(wedgeCount == 1)
    }

    private func failingPolicy() -> RestartPolicyConfig {
        RestartPolicyConfig(startupGrace: 5, initialBackoff: 1, backoffMultiplier: 2, maxBackoff: 60,
                            crashLoopThreshold: 3, crashLoopWindow: 600, failingProbeInterval: 30)
    }

    private func killCurrent(_ h: Harness) {
        if let handle = h.processes.lastHandle {
            h.processes.simulateExit(handle, exit: ProcessExit(code: 1), stderr: ["boom"])
        }
    }

    private func enteredFailingCount(_ h: Harness) async -> Int {
        await h.notifier.received.filter {
            if case .enteredFailing? = $0.event { return true }; return false
        }.count
    }

    /// Drive a never-serving runner through three crashes into the failing wait
    /// state. Returns the wait the failing transition asked for.
    @discardableResult
    private func driveIntoFailing(_ h: Harness) async -> TimeInterval {
        await h.engine.start()                          // spawn 1, starting
        for backoff in [1.0, 2.0] {                     // two normal-backoff deaths
            killCurrent(h)
            _ = await h.engine.stepOnce()               // detect -> down
            h.clock.advance(by: backoff + 0.01)
            _ = await h.engine.stepOnce()               // respawn -> restarting
        }
        killCurrent(h)
        return await h.engine.stepOnce()                // third death trips failing
    }

    @Test func rapidCrashesEnterFailingAndRetrySlowly() async {
        let h = makeHarness(policy: failingPolicy())
        let failingWait = await driveIntoFailing(h)

        #expect(await h.engine.snapshot().phase == .failing)
        #expect(failingWait == 30)                      // the slow cadence brake is on, not fast backoff
        #expect(await enteredFailingCount(h) == 1)
        let spawnsBefore = h.processes.spawnCount

        // The slow timer fires: it keeps retrying (the old bug froze here forever)
        // but moves through restarting so the fresh child is actually probed.
        h.clock.advance(by: failingWait + 0.01)
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .restarting)
        #expect(h.processes.spawnCount == spawnsBefore + 1)
    }

    @Test func aLongHealthyRunnerIsMaintenanceRestarted() async {
        let policy = RestartPolicyConfig(startupGrace: 5, maintenanceRestartInterval: 3600)
        let h = makeHarness(policy: policy)
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()   // -> healthy
        #expect(await h.engine.snapshot().phase == .healthy)
        let spawnsBefore = h.processes.spawnCount

        // Not yet due: a healthy step does not cycle the runner.
        h.clock.advance(by: 100)
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == spawnsBefore)

        // Past the interval: the next healthy step cycles the runner (a fresh
        // spawn) and moves to restarting.
        h.clock.advance(by: 3601)
        _ = await h.engine.stepOnce()
        #expect(h.processes.spawnCount == spawnsBefore + 1)
        #expect(await h.engine.snapshot().phase == .restarting)
    }

    @Test func aCrashLoopedRunnerRecoversWhenItComesBack() async {
        let h = makeHarness(policy: failingPolicy())
        _ = await driveIntoFailing(h)
        #expect(await h.engine.snapshot().phase == .failing)

        // The runner comes back: stop killing it and let readiness succeed. This is
        // the regression for the failing-trap bug: a crash loop that recovers must
        // be detected, not left stuck forever.
        makeServing(h)
        h.clock.advance(by: 30.01)
        _ = await h.engine.stepOnce()                   // slow retry -> restarting (fresh, serving child)
        #expect(await h.engine.snapshot().phase == .restarting)
        _ = await h.engine.stepOnce()                   // probe -> serving -> recover
        #expect(await h.engine.snapshot().phase == .healthy)
        let recovered = await h.notifier.received.filter { $0.event == .recovered }.count
        #expect(recovered == 1)
    }

    @Test func stopReleasesPowerAndTerminatesChild() async {
        let h = makeHarness()
        makeServing(h)
        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)
        #expect(h.power.isHeld)

        await h.engine.stop()

        #expect(await h.engine.snapshot().phase == .stopped)
        #expect(!h.power.isHeld)
        #expect(h.power.releases == 1)
        #expect(h.processes.terminateCount >= 1)
    }

    @Test func spawnFailureFunnelsIntoRestartPath() async {
        let h = makeHarness(policy: RestartPolicyConfig(startupGrace: 0, initialBackoff: 1))
        struct SpawnFail: Error {}
        h.processes.failNextSpawns(with: SpawnFail())

        await h.engine.start()
        // The spawn failed, so there is no live child; the next step detects that
        // and schedules a restart rather than wedging.
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .down)
    }

    @Test func respawnSweepsThePreviousRunnerBeforeSpawning() async throws {
        let h = makeHarness(policy: RestartPolicyConfig(startupGrace: 0, initialBackoff: 1))
        makeServing(h)
        await h.engine.start()                       // spawn #1
        _ = await h.engine.stepOnce()                // -> healthy
        let first = try #require(h.processes.lastHandle)

        // Crash the runner. A crash, like an external kill, emits no kill effect,
        // so the only thing that reaps the old runner tree is the pre-spawn sweep.
        h.processes.simulateExit(first, exit: ProcessExit(code: 1), stderr: ["boom"])
        let wait = await h.engine.stepOnce()         // detect dead -> down
        h.clock.advance(by: wait + 0.01)
        _ = await h.engine.stepOnce()                // respawn

        // The engine terminated the previous handle before spawning the new one,
        // so a crash-orphaned grandchild cannot stack up across a restart loop.
        #expect(h.processes.terminatedHandles.contains(first))
        #expect(h.processes.spawnCount == 2)
    }

    // MARK: - Deep readiness probe

    /// The inference-only wedge: /api/version answers, but /api/generate hangs.
    /// Without a deep probe, Hearth cannot see it and stays healthy.
    @Test func shallowProbeMissesAnInferenceWedge() async {
        let h = makeHarness()                       // no deep probe
        makeServing(h)
        h.http.set(h.runner.deepReadinessRequest(model: "llama3:8b")!.url, .timedOut)

        await h.engine.start()
        _ = await h.engine.stepOnce()
        #expect(await h.engine.snapshot().phase == .healthy)   // blind to the wedge
    }

    /// With a deep probe, the same wedge is caught: the deep request times out, so
    /// the runner is treated as not ready and restarted, unlike the shallow case.
    @Test func deepProbeCatchesAnInferenceWedge() async {
        let h = makeHarness(deepProbe: DeepProbeConfig(model: "llama3:8b", interval: 60, timeout: 30))
        makeServing(h)
        let deepURL = h.runner.deepReadinessRequest(model: "llama3:8b")!.url
        h.http.set(deepURL, .ok(Data("{}".utf8)))   // inference works at first

        await h.engine.start()
        _ = await h.engine.stepOnce()                // shallow + deep ok -> healthy
        #expect(await h.engine.snapshot().phase == .healthy)

        // The model runner wedges: /api/generate now hangs, /api/version still answers.
        h.http.set(deepURL, .timedOut)
        h.clock.advance(by: 61)                       // the deep probe is due again
        _ = await h.engine.stepOnce()

        #expect(await h.engine.snapshot().phase != .healthy)   // caught it
    }
}
