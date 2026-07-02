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

    // MARK: - the shutdown kill

    /// Spawn `/bin/sh -c command` as the leader of its OWN process group (as the
    /// controller does), so the group signals in this test can never land on the
    /// test runner's group.
    private func spawnDetachedGroupLeader(_ command: String) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        defer { posix_spawnattr_destroy(&attr) }
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        let rc = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, "/bin/sh", nil, &attr, buffer.baseAddress, nil)
        }
        try #require(rc == 0)
        return pid
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    @Test func shutdownKillReachesAGroupWhoseLeaderIsAnUnreapedZombie() throws {
        // The shutdown leak shape: the leader exits (as `ollama serve` does on
        // SIGTERM) and sits unreaped as a zombie, while a group member that
        // outlives it (as a wedged llama-server holding GPU memory does)
        // survives in the group. killRecordedGroupNow must still take the group
        // down; gating it on a probeable leader skipped exactly this case.
        let file = TestIsolation.path("zombie-shutdown.json")
        let memberPidFile = TestIsolation.path("zombie-member.pid")
        let leader = try spawnDetachedGroupLeader(
            "sleep 30 & echo $! > '\(memberPidFile.path)'; sleep 0.2")
        defer {
            killpg(leader, SIGKILL)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }
        let identity = try #require(RunnerStateStore.liveIdentity(pid: leader, pgid: leader))
        try JSONEncoder().encode([identity]).write(to: file)

        // The leader becomes an unreaped zombie: no probeable identity, while
        // the recorded group member is still alive.
        #expect(eventually { RunnerStateStore.liveIdentity(pid: leader) == nil })
        let memberText = try String(contentsOf: memberPidFile, encoding: .utf8)
        let member = try #require(pid_t(memberText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(member, 0) == 0)

        RunnerStateStore.killRecordedGroupNow(at: file)
        #expect(eventually { kill(member, 0) != 0 })
    }
}
