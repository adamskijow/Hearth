// SPDX-License-Identifier: MIT

import Testing
import Foundation
import SupervisorCore
@testable import Hearth

/// The runner-state file's set semantics: append at spawn, remove on a confirmed
/// reap, prune stale records, and stay readable across the old single-identity
/// format. These tests use explicit file URLs so they are isolated from each
/// other and from the spawning integration tests.
struct RunnerStateStoreTests {
    init() {
        _ = TestIsolation.scratch
    }

    /// A real live process (a plain child in our own group; nothing here sends
    /// group signals) whose identity can be recorded and pruned honestly.
    private func liveChild() throws -> (Process, RunnerProcessIdentity) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let identity = try #require(RunnerStateStore.liveIdentity(pid: process.processIdentifier))
        return (process, identity)
    }

    private func reap(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }

    @Test func readsTheSingleIdentityFormatFromOlderVersions() throws {
        let file = TestIsolation.path("old-format.json")
        let identity = RunnerProcessIdentity(
            pid: 4242, pgid: 4242, startTimeSeconds: 1_700_000_000,
            executablePath: "/opt/homebrew/bin/ollama")
        try JSONEncoder().encode(identity).write(to: file)
        #expect(RunnerStateStore.loadRecorded(at: file) == [identity])
    }

    @Test func recordKeepsLivePredecessorsAndPrunesDeadOnes() throws {
        let file = TestIsolation.path("state.json")
        let (childA, a) = try liveChild()
        let (childB, b) = try liveChild()
        defer { reap(childB) }

        RunnerStateStore.record(a, at: file)
        RunnerStateStore.record(b, at: file)
        // Both are live, so the predecessor is kept: it may still be inside a
        // kill grace window and must stay sweepable.
        #expect(RunnerStateStore.loadRecorded(at: file) == [a, b])

        // Once a recorded process is dead, the next append prunes its record.
        reap(childA)
        let (childC, c) = try liveChild()
        defer { reap(childC) }
        RunnerStateStore.record(c, at: file)
        #expect(RunnerStateStore.loadRecorded(at: file) == [b, c])
    }

    @Test func removeDropsOnlyTheExactInstance() throws {
        let file = TestIsolation.path("remove.json")
        let (child, identity) = try liveChild()
        defer { reap(child) }
        // A successor that reused the pid (different start time) must survive a
        // slow removal of the old instance.
        let successor = RunnerProcessIdentity(
            pid: identity.pid, pgid: identity.pgid,
            startTimeSeconds: identity.startTimeSeconds &+ 5)
        try JSONEncoder().encode([identity, successor]).write(to: file)

        RunnerStateStore.remove(identity, at: file)
        #expect(RunnerStateStore.loadRecorded(at: file) == [successor])
    }

    @Test func removingTheLastIdentityDeletesTheFile() throws {
        let file = TestIsolation.path("empty.json")
        let (child, identity) = try liveChild()
        defer { reap(child) }

        RunnerStateStore.record(identity, at: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        RunnerStateStore.remove(identity, at: file)
        #expect(RunnerStateStore.loadRecorded(at: file).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func recordReplacesAnOlderRecordWithTheSamePid() throws {
        let file = TestIsolation.path("same-pid.json")
        let (child, identity) = try liveChild()
        defer { reap(child) }
        let older = RunnerProcessIdentity(
            pid: identity.pid, pgid: identity.pgid,
            startTimeSeconds: identity.startTimeSeconds &- 100)
        try JSONEncoder().encode([older]).write(to: file)

        RunnerStateStore.record(identity, at: file)
        #expect(RunnerStateStore.loadRecorded(at: file) == [identity])
    }
}
