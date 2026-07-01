// SPDX-License-Identifier: MIT

import Testing
import Foundation
import SupervisorCore
@testable import Hearth

/// Integration tests that drive the real process controller against real,
/// short-lived children. Serialized: they observe the shared runner-state file
/// (relocated into a scratch directory by `TestIsolation`) and real process
/// lifecycles, so interleaved spawns would read each other's records.
@Suite(.serialized)
struct ProcessControllerTests {
    init() {
        _ = TestIsolation.scratch
    }

    private func makeController(grace: Double) -> FoundationProcessController {
        FoundationProcessController(
            logFileURL: TestIsolation.path("runner.log"),
            killGraceSeconds: grace
        )
    }

    private func spec(_ path: String, _ arguments: [String] = []) -> ProcessSpec {
        ProcessSpec(executableURL: URL(fileURLWithPath: path), arguments: arguments)
    }

    private func recordedPIDs() -> [pid_t] {
        RunnerStateStore.loadRecorded().map(\.pid)
    }

    @Test func spawnTerminateKillsTheWholeGroupAndConfirmsTheReap() async throws {
        let controller = makeController(grace: 0.2)
        let id = try controller.spawn(spec("/bin/sleep", ["30"]))
        let pid = try #require(RunnerStateStore.loadRecorded().last?.pid)
        #expect(controller.status(id).isAlive)

        controller.terminate(id)
        // The whole group dies and the leader is reaped (a zombie would keep the
        // group id alive, so groupIsGone also proves the reap happened).
        #expect(await eventually { groupIsGone(pid) })
        // The entry is dropped: an unknown handle reports not alive with no exit.
        #expect(await eventually {
            let status = controller.status(id)
            return !status.isAlive && status.exit == nil
        })
        // The crash-recovery record is removed once the reap is confirmed.
        #expect(await eventually { !self.recordedPIDs().contains(pid) })
    }

    @Test func externallyKilledChildIsReapedAndItsExitReported() async throws {
        let controller = makeController(grace: 0.1)
        let id = try controller.spawn(spec("/bin/sleep", ["30"]))
        let pid = try #require(RunnerStateStore.loadRecorded().last?.pid)
        #expect(controller.status(id).isAlive)

        kill(pid, SIGKILL)
        #expect(await eventually {
            let status = controller.status(id)
            return !status.isAlive && status.exit?.wasSignaled == true && status.exit?.signal == SIGKILL
        })

        // The leader is already reaped, so its pid (and pgid) may be recycled:
        // terminate must skip the deferred group SIGKILL rather than signal a
        // bystander, and still clean up the entry and the record.
        controller.terminate(id)
        #expect(await eventually { controller.status(id).exit == nil })
        #expect(await eventually { !self.recordedPIDs().contains(pid) })
    }

    @Test func terminateIsIdempotent() async throws {
        let controller = makeController(grace: 0.1)
        let id = try controller.spawn(spec("/bin/sleep", ["30"]))
        let pid = try #require(RunnerStateStore.loadRecorded().last?.pid)

        controller.terminate(id)
        controller.terminate(id)   // again, while the first grace window is pending
        #expect(await eventually { groupIsGone(pid) })
        #expect(await eventually { controller.status(id).exit == nil })

        controller.terminate(id)   // and again, after the entry is long gone
        #expect(!controller.status(id).isAlive)
    }

    @Test func rapidSpawnTerminateCyclesDoNotCrashOrLeak() async throws {
        let logFile = TestIsolation.path("stress-runner.log")
        let controller = FoundationProcessController(logFileURL: logFile, killGraceSeconds: 0.05)
        var ids: [ProcessHandleID] = []
        var pids: [pid_t] = []
        func logBytes() -> UInt64 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path)
            return (attributes?[.size] as? UInt64) ?? 0
        }
        for cycle in 0..<40 {
            // A child that floods both pipes, so the pipe drains race the
            // teardown's fd close. Alternate a cold teardown (terminate before
            // any output flowed) with a hot one (terminate while the drains are
            // demonstrably pumping, observed via log growth). The old
            // readabilityHandler code called `availableData` in a race with the
            // close in finishReading, which raises an uncatchable
            // NSFileHandleOperationException once it loses.
            let id = try controller.spawn(spec(
                "/bin/sh", ["-c", "while :; do echo out; echo err 1>&2; done"]))
            ids.append(id)
            if let pid = RunnerStateStore.loadRecorded().last?.pid { pids.append(pid) }
            if cycle % 2 == 0 {
                // The baseline is taken after the spawn banner, so growth can
                // only come from the child's own output.
                let baseline = logBytes()
                _ = await eventually(timeout: 2) { logBytes() > baseline }   // drains are hot
            }
            if cycle % 3 == 0 {
                _ = controller.status(id)   // interleave the probe path too
            }
            controller.terminate(id)
        }
        // Everything spawned is dead and reaped, every entry dropped, and every
        // crash-recovery record confirmed-removed: nothing leaked.
        #expect(await eventually(timeout: 15) { pids.allSatisfy { groupIsGone($0) } })
        #expect(await eventually(timeout: 15) {
            ids.allSatisfy { controller.status($0).exit == nil && !controller.status($0).isAlive }
        })
        #expect(await eventually(timeout: 15) {
            Set(self.recordedPIDs()).isDisjoint(with: pids)
        })
    }

    @Test func wedgedPredecessorStaysRecordedUntilItsReapIsConfirmed() async throws {
        let controller = makeController(grace: 0.5)
        // A leader that ignores SIGTERM, like a wedged runner: its short-lived
        // sleep children absorb the group SIGTERM while the leader survives, so
        // only the deferred group SIGKILL takes it down. The ready file proves
        // the trap is installed before the SIGTERM flies, else the shell dies
        // like any ordinary child.
        let ready = TestIsolation.path("wedge-ready")
        let wedged = try controller.spawn(spec(
            "/bin/sh", ["-c", "trap '' TERM; touch '\(ready.path)'; while :; do sleep 0.2; done"]))
        let wedgedPID = try #require(RunnerStateStore.loadRecorded().last?.pid)
        #expect(await eventually { FileManager.default.fileExists(atPath: ready.path) })

        // The restart sequence, exactly as SupervisorEngine.spawnChild runs it:
        // terminate the old runner, then immediately spawn and record the new one.
        controller.terminate(wedged)
        let fresh = try controller.spawn(spec("/bin/sleep", ["30"]))
        let freshPID = try #require(RunnerStateStore.loadRecorded().last?.pid)

        // Both identities are recorded while the old group sits in its grace
        // window, so a hard SIGKILL of Hearth right here leaves the wedged group
        // sweepable at the next launch. (The old single-identity store was
        // overwritten by the new spawn, orphaning the predecessor.)
        let during = recordedPIDs()
        #expect(during.contains(wedgedPID))
        #expect(during.contains(freshPID))
        #expect(kill(wedgedPID, 0) == 0)   // still alive: it ignored the SIGTERM

        // After the grace, the deferred SIGKILL lands (the unreaped leader keeps
        // the pgid provably ours), the reap confirms, and only then is the old
        // record dropped, leaving just the fresh runner.
        #expect(await eventually { groupIsGone(wedgedPID) })
        #expect(await eventually { !self.recordedPIDs().contains(wedgedPID) })
        #expect(recordedPIDs().contains(freshPID))

        controller.terminate(fresh)
        #expect(await eventually { groupIsGone(freshPID) })
    }

    @Test func sweepOrphanKillsTheRecordedLiveGroup() async throws {
        let controller = makeController(grace: 0.2)
        let id = try controller.spawn(spec("/bin/sleep", ["30"]))
        let identity = try #require(RunnerStateStore.loadRecorded().last)

        // A crashed previous Hearth left this state file behind.
        let file = TestIsolation.path("orphan-state.json")
        RunnerStateStore.record(identity, at: file)

        let swept = RunnerStateStore.sweepOrphan(at: file)
        #expect(swept?.contains("pid \(identity.pid)") == true)
        #expect(RunnerStateStore.loadRecorded(at: file).isEmpty)
        // The sweep's SIGTERM landed: the controller reaps it and reports the signal.
        #expect(await eventually {
            let status = controller.status(id)
            return !status.isAlive && status.exit?.signal == SIGTERM
        })
        controller.terminate(id)
        #expect(await eventually { groupIsGone(identity.pgid) })
    }

    @Test func sweepOrphanNeverSignalsARecycledIdentity() async throws {
        let controller = makeController(grace: 0.2)
        let id = try controller.spawn(spec("/bin/sleep", ["30"]))
        let identity = try #require(RunnerStateStore.loadRecorded().last)

        // The same pid but a different start time: the pid was recycled by an
        // unrelated process as far as the sweep can tell. It must not be signalled.
        let recycled = RunnerProcessIdentity(
            pid: identity.pid, pgid: identity.pgid,
            startTimeSeconds: identity.startTimeSeconds &+ 7)
        let file = TestIsolation.path("recycled-state.json")
        RunnerStateStore.record(recycled, at: file)

        #expect(RunnerStateStore.sweepOrphan(at: file) == nil)
        #expect(RunnerStateStore.loadRecorded(at: file).isEmpty)   // stale record dropped
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.status(id).isAlive)   // the live child was left alone

        controller.terminate(id)
        #expect(await eventually { groupIsGone(identity.pgid) })
    }
}
