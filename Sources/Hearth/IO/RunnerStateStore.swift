// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Persists the identity of the runner Hearth spawned, so that if Hearth is
/// killed without running its teardown (a hard SIGKILL or a panic), the next
/// launch can find and sweep the leaked runner group before starting fresh.
enum RunnerStateStore {
    static var url: URL {
        AppPaths.supportDirectory.appendingPathComponent("runner-state.json")
    }

    /// Record the just spawned runner (it is the group leader, so pgid == pid).
    static func record(pid: pid_t, pgid: pid_t) {
        guard let identity = liveIdentity(pid: pid, pgid: pgid) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(identity) else { return }
        SecureFile.write(data, to: url)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
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

    /// If a runner recorded by a previous, crashed Hearth is still alive (same PID
    /// and start time), kill its whole group. Returns a short description when it
    /// swept something. Stale records (process gone or PID recycled) are dropped.
    @discardableResult
    static func sweepOrphan() -> String? {
        guard let data = try? Data(contentsOf: url),
              let recorded = try? JSONDecoder().decode(RunnerProcessIdentity.self, from: data) else {
            return nil
        }
        let live = liveIdentity(pid: recorded.pid)
        guard RunnerSweep.shouldSweep(recorded: recorded, live: live) else {
            clear()
            return nil
        }
        let pgid = recorded.pgid
        killpg(pgid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if killpg(pgid, 0) == 0 { killpg(pgid, SIGKILL) }
        }
        clear()
        let exe = recorded.executablePath.map { " (\($0))" } ?? ""
        return "swept an orphaned runner from a previous run: pgid \(pgid), pid \(recorded.pid)\(exe)"
    }

    /// Synchronously ensure the recorded runner group is dead, for the shutdown
    /// path. The engine's teardown sends SIGTERM but schedules its SIGKILL backup
    /// on a queue that dies when the process exits, so a wedged child that ignores
    /// SIGTERM could be outrun by exit(). This SIGKILLs whatever is left, after the
    /// same start-time guard so it never kills a PID-recycled bystander.
    static func killRecordedGroupNow() {
        guard let data = try? Data(contentsOf: url),
              let recorded = try? JSONDecoder().decode(RunnerProcessIdentity.self, from: data) else {
            return
        }
        guard RunnerSweep.shouldSweep(recorded: recorded, live: liveIdentity(pid: recorded.pid)) else { return }
        if killpg(recorded.pgid, 0) == 0 {
            killpg(recorded.pgid, SIGKILL)
        }
    }
}
