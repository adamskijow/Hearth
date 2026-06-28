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

    private func makeHarness(policy: RestartPolicyConfig = RestartPolicyConfig(startupGrace: 30)) -> Harness {
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
            policy: policy
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
}
