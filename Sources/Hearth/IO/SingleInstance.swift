// SPDX-License-Identifier: MIT

import Foundation

/// A whole-process guard so only one Hearth supervises a given config at a time.
/// Two supervisors on one machine fight over the runner (each spawns and kills the
/// other's), which is exactly what happens if both the menubar app and a headless
/// LaunchAgent run. The lock is keyed to the config path, so two instances pointed
/// at the same config share it, while genuinely separate configs (different
/// runners) do not. It is an advisory `flock` the kernel releases automatically
/// when the holder exits, so a crash never leaves it stale, and a waiting instance
/// takes over the moment the holder dies.
enum SingleInstance {
    /// Acquire the supervisor lock for `configPath`. When `wait` is false the call
    /// returns immediately, with false if another instance already holds the lock
    /// (the menubar app uses this so it never hangs). When `wait` is true the call
    /// blocks until the lock is free, becoming a hot standby that takes over when
    /// the current holder exits (the headless job uses this, so it does not fight
    /// the holder or respawn-loop under launchd `KeepAlive`). `onWait` fires once if
    /// the call is about to block. On success the lock is held for the rest of the
    /// process's life.
    @discardableResult
    static func acquire(configPath: URL = AppPaths.configFile,
                        wait: Bool,
                        onWait: (() -> Void)? = nil) -> Bool {
        let lockPath = configPath.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }  // cannot create a lock file; do not block startup over it

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Contended: another instance holds the lock.
            guard wait else { close(fd); return false }
            onWait?()
            guard flock(fd, LOCK_EX) == 0 else { close(fd); return false }
        }

        // Record our pid for anyone inspecting the file, and keep the descriptor
        // open (held for the process lifetime) so the lock stays ours.
        ftruncate(fd, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        heldFD = fd
        return true
    }

    /// Keeps the lock file descriptor open for the life of the process. Assigned
    /// once, at startup, before any concurrency begins.
    nonisolated(unsafe) private static var heldFD: Int32 = -1
}
