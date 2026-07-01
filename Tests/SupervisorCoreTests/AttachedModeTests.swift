// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Attached mode monitors a runner it does not own: it probes readiness, holds
/// power, and notifies on transitions, but never spawns or kills a process.
struct AttachedModeTests {
    private func makeEngine(deepProbe: DeepProbeConfig? = nil) -> (SupervisorEngine, ManualClock, FakeProcessController, FakeHTTPClient, FakePowerManager, FakeNotifier, OllamaRunner) {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 0))
        let processes = FakeProcessController()
        let http = FakeHTTPClient()
        let power = FakePowerManager()
        let notifier = FakeNotifier()
        let runner = OllamaRunner(binaryPath: "/unused", host: "127.0.0.1", port: 11434)
        let engine = SupervisorEngine(
            clock: clock, processes: processes, http: http, runner: runner,
            power: power, notifier: notifier,
            policy: RestartPolicyConfig(startupGrace: 0, initialBackoff: 1),
            managed: false,
            deepProbe: deepProbe
        )
        return (engine, clock, processes, http, power, notifier, runner)
    }

    @Test func neverSpawnsButHoldsPowerAndGoesHealthy() async {
        let (engine, _, processes, http, power, _, runner) = makeEngine()
        http.set(runner.readinessEndpoint, .ok(Data(#"{"version":"x"}"#.utf8)))
        http.set(runner.modelsEndpoint, .ok(Data(#"{"models":[{"name":"llama3"}]}"#.utf8)))

        await engine.start()
        #expect(processes.spawnCount == 0)   // attached mode does not spawn
        #expect(power.isHeld)                // but it still keeps the Mac awake

        _ = await engine.stepOnce()          // probe readiness -> healthy
        let state = await engine.snapshot()
        #expect(state.phase == .healthy)
        #expect(state.residentModels.map(\.name) == ["llama3"])
        #expect(processes.spawnCount == 0)
    }

    @Test func unreachableGoesDownWithoutKillingAnything() async {
        let (engine, _, processes, http, _, notifier, runner) = makeEngine()
        http.set(runner.readinessEndpoint, .ok(Data(#"{"version":"x"}"#.utf8)))
        http.set(runner.modelsEndpoint, .ok(Data(#"{"models":[]}"#.utf8)))
        await engine.start()
        _ = await engine.stepOnce()
        #expect(await engine.snapshot().phase == .healthy)

        // The external runner stops answering.
        http.set(runner.readinessEndpoint, .timedOut)
        _ = await engine.stepOnce()

        #expect(await engine.snapshot().phase == .down)
        #expect(processes.terminateCount == 0)   // we do not own it, so we never kill
        #expect(processes.spawnCount == 0)
        let downCount = await notifier.received.filter { if case .down? = $0.event { return true }; return false }.count
        #expect(downCount == 1)
    }

    @Test func recoversWhenTheRunnerComesBack() async {
        let (engine, clock, processes, http, _, notifier, runner) = makeEngine()
        http.set(runner.readinessEndpoint, .ok(Data(#"{"version":"x"}"#.utf8)))
        http.set(runner.modelsEndpoint, .ok(Data(#"{"models":[]}"#.utf8)))
        await engine.start()
        _ = await engine.stepOnce()

        http.set(runner.readinessEndpoint, .timedOut)
        let wait = await engine.stepOnce()                  // -> down
        #expect(await engine.snapshot().phase == .down)

        // It comes back; the down timer elapses and a probe finds it healthy.
        http.set(runner.readinessEndpoint, .ok(Data(#"{"version":"x"}"#.utf8)))
        clock.advance(by: wait + 0.01)
        _ = await engine.stepOnce()                         // respawn (skipped) -> restarting
        _ = await engine.stepOnce()                         // probe -> healthy

        #expect(await engine.snapshot().phase == .healthy)
        let recovered = await notifier.received.filter { $0.event == .recovered }.count
        #expect(recovered == 1)
        #expect(processes.spawnCount == 0)        // still never spawned
    }

    /// The regression for the false-recovery bug: a failed deep probe must not be
    /// cached like a pass. Attached mode never spawns, so nothing else resets the
    /// deep-probe timestamp; caching the failure let the next shallow-ready cycle
    /// skip the deep probe and report a still-wedged runner as recovered.
    @Test func aWedgedRunnerStaysDownAndNeverFalselyRecovers() async {
        let (engine, clock, _, http, _, notifier, runner) = makeEngine(
            deepProbe: DeepProbeConfig(model: "llama3", interval: 60, timeout: 30))
        http.set(runner.readinessEndpoint, .ok(Data(#"{"version":"x"}"#.utf8)))
        http.set(runner.modelsEndpoint, .ok(Data(#"{"models":[]}"#.utf8)))
        let deepURL = runner.deepReadinessRequest(model: "llama3")!.url
        http.set(deepURL, .ok(Data("{}".utf8)))   // inference works at first

        await engine.start()
        _ = await engine.stepOnce()                     // shallow + deep ok -> healthy
        #expect(await engine.snapshot().phase == .healthy)

        // The runner wedges: /api/version still answers, inference hangs.
        http.set(deepURL, .timedOut)
        clock.advance(by: 61)                           // the deep probe is due again
        var wait = await engine.stepOnce()              // deep probe fails -> down
        #expect(await engine.snapshot().phase != .healthy)

        // Drive several retry cycles, all well inside the deep-probe interval.
        // The still-wedged runner must fail the deep probe every cycle rather
        // than pass on a cached timestamp and fire a spurious recovery.
        for _ in 0..<6 {
            clock.advance(by: wait + 0.01)
            wait = await engine.stepOnce()
            #expect(await engine.snapshot().phase != .healthy)
        }
        let recovered = await notifier.received.filter { $0.event == .recovered }.count
        #expect(recovered == 0)
    }

    @Test func stopReleasesPower() async {
        let (engine, _, _, http, power, _, runner) = makeEngine()
        http.set(runner.readinessEndpoint, .ok(Data(#"{"version":"x"}"#.utf8)))
        await engine.start()
        _ = await engine.stepOnce()
        #expect(power.isHeld)
        await engine.stop()
        #expect(!power.isHeld)
    }
}
