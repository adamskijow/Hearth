// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Persists the identities of the runners Hearth spawned, so that if Hearth is
/// killed without running its teardown (a hard SIGKILL or a panic), the next
/// launch can find and sweep the leaked runner groups before starting fresh.
///
/// This is a small set, not a single record: during a restart the old group is
/// only SIGTERMed and given a grace window while the new one is already spawned
/// and recorded. If the file held one identity, recording the new runner would
/// overwrite the old one, and a hard kill of Hearth inside that window would
/// orphan a wedged old group beyond the sweep's reach. Identities are appended
/// at spawn and removed only once the leader's reap is confirmed, so both
/// groups stay recoverable across the window. In steady state the file holds
/// exactly one identity.
enum RunnerStateStore {
    /// Serializes the read-modify-write cycles below; spawns run on the engine
    /// actor while confirmed reaps arrive from a background queue.
    private static let lock = NSLock()

    /// Test seam: relocates the state file so integration tests never touch the
    /// real support directory. Set once at test bootstrap, before anything spawns.
    nonisolated(unsafe) static var urlOverride: URL?

    static var url: URL {
        urlOverride ?? AppPaths.supportDirectory.appendingPathComponent("runner-state.json")
    }

    /// Every recorded identity. Reads both the current array format and the
    /// single-identity object written by older versions, so an upgrade across
    /// this change still sweeps a pre-upgrade orphan.
    static func loadRecorded(at url: URL = RunnerStateStore.url) -> [RunnerProcessIdentity] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let identities = try? JSONDecoder().decode([RunnerProcessIdentity].self, from: data) {
            return identities
        }
        if let single = try? JSONDecoder().decode(RunnerProcessIdentity.self, from: data) {
            return [single]
        }
        return []
    }

    /// Record the just spawned runner (it is the group leader, so pgid == pid).
    /// Returns the captured identity so the caller can hand it back to `remove`
    /// once the reap is confirmed.
    @discardableResult
    static func record(pid: pid_t, pgid: pid_t) -> RunnerProcessIdentity? {
        guard let identity = liveIdentity(pid: pid, pgid: pgid) else { return nil }
        record(identity)
        return identity
    }

    /// Append an identity, pruning any stale records (process gone or PID
    /// recycled) so the file cannot grow across crashy restarts. A still-live
    /// predecessor is deliberately kept: it is only SIGTERMed at this point and
    /// must stay sweepable if Hearth dies inside the kill grace window.
    static func record(_ identity: RunnerProcessIdentity, at url: URL = RunnerStateStore.url) {
        lock.withLock {
            var identities = loadRecorded(at: url).filter { recorded in
                recorded.pid != identity.pid
                    && RunnerSweep.shouldSweep(recorded: recorded, live: liveIdentity(pid: recorded.pid))
            }
            identities.append(identity)
            write(identities, to: url)
        }
    }

    /// Forget one identity after its teardown is confirmed (the leader was
    /// reaped). Matches on pid AND start time so a slow removal can never drop
    /// the record of a successor that reused the pid.
    static func remove(_ identity: RunnerProcessIdentity, at url: URL = RunnerStateStore.url) {
        lock.withLock {
            let identities = loadRecorded(at: url).filter {
                !($0.pid == identity.pid && $0.startTimeSeconds == identity.startTimeSeconds)
            }
            write(identities, to: url)
        }
    }

    static func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }

    private static func write(_ identities: [RunnerProcessIdentity], to url: URL) {
        guard !identities.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(identities) else { return }
        SecureFile.write(data, to: url)
    }

    /// Probe a live process by PID, capturing its current start time and exe path,
    /// or nil if the process is gone.
    static func liveIdentity(pid: pid_t, pgid: pid_t? = nil) -> RunnerProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard written == size else { return nil }

        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the macro is not imported.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let exe = pathLength > 0 ? pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : nil

        return RunnerProcessIdentity(
            pid: pid,
            pgid: pgid ?? Int32(info.pbi_pgid),
            startTimeSeconds: info.pbi_start_tvsec,
            executablePath: exe
        )
    }

    /// If any runner recorded by a previous, crashed Hearth is still alive (same
    /// PID and start time), kill its whole group. Returns a short description
    /// when it swept something. Stale records (process gone or PID recycled) are
    /// dropped without signalling anything.
    @discardableResult
    static func sweepOrphan(at url: URL = RunnerStateStore.url) -> String? {
        let recordedIdentities: [RunnerProcessIdentity] = lock.withLock {
            let identities = loadRecorded(at: url)
            try? FileManager.default.removeItem(at: url)
            return identities
        }
        var swept: [String] = []
        for recorded in recordedIdentities {
            guard RunnerSweep.shouldSweep(recorded: recorded, live: liveIdentity(pid: recorded.pid)) else {
                continue
            }
            let pgid = recorded.pgid
            killpg(pgid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                // Re-check the leader before the backup SIGKILL: this orphan was
                // reparented to launchd, which reaps it the moment SIGTERM lands,
                // freeing the pgid for reuse inside this window. Only a leader
                // that is still the same instance proves the group is still ours.
                guard RunnerSweep.shouldSweep(recorded: recorded, live: liveIdentity(pid: recorded.pid)) else {
                    return
                }
                if killpg(pgid, 0) == 0 { killpg(pgid, SIGKILL) }
            }
            let exe = recorded.executablePath.map { " (\($0))" } ?? ""
            swept.append("pgid \(pgid), pid \(recorded.pid)\(exe)")
        }
        guard !swept.isEmpty else { return nil }
        return "swept an orphaned runner from a previous run: " + swept.joined(separator: "; ")
    }

    /// Synchronously ensure every recorded runner group is dead, for the shutdown
    /// path. The engine's teardown sends SIGTERM but schedules its SIGKILL backup
    /// on a queue that dies when the process exits, so a wedged child that ignores
    /// SIGTERM could be outrun by exit(). This SIGKILLs whatever is left.
    ///
    /// The gate is `deferredKillAllowed`, NOT `shouldSweep`: at shutdown the
    /// common leak shape is a leader that already exited on SIGTERM (an unreaped
    /// zombie, which reports no probeable info) while a wedged group member
    /// ignores SIGTERM and survives holding GPU memory. `shouldSweep` refuses on
    /// an unprobeable leader and would skip exactly that case; an unreaped zombie
    /// keeps its pid (and so the pgid) reserved, so the group SIGKILL is safe. A
    /// record is only removed after its reap is confirmed, so a present record
    /// means unreaped, and the start-time check still refuses when the pid was
    /// somehow recycled by a probeable newcomer.
    static func killRecordedGroupNow(at url: URL = RunnerStateStore.url) {
        for recorded in loadRecorded(at: url) {
            guard RunnerSweep.deferredKillAllowed(leaderReaped: false,
                                                  spawn: recorded,
                                                  live: liveIdentity(pid: recorded.pid)) else {
                continue
            }
            if killpg(recorded.pgid, 0) == 0 {
                killpg(recorded.pgid, SIGKILL)
            }
        }
    }
}
