// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// posix_spawn failed with this non-zero return code.
struct SpawnError: Error { let code: Int32 }

/// The real process controller. It spawns the runner with `posix_spawn` in a NEW
/// process group (the child becomes the group leader), captures stdout and stderr
/// to a size rotated log file, keeps a ring of recent stderr for exit
/// classification, and on teardown kills the WHOLE group with `killpg`.
///
/// The process group matters: `ollama serve` forks a separate `llama-server`
/// child that holds GPU and unified memory. Signalling only the serve PID would
/// orphan that grandchild on every restart and leak memory. Killing the group
/// takes the entire runner tree down together. Confirmed against a real Ollama.
///
/// Thread safe by a lock: pipe readability handlers fire on background queues,
/// while the engine calls `status` from its actor.
final class FoundationProcessController: ProcessControlling, @unchecked Sendable {
    private final class Entry {
        let pid: pid_t
        let pgid: pid_t
        let stdoutRead: FileHandle
        let stderrRead: FileHandle
        var stderrRing: [String] = []
        var partialStderr = Data()
        var exit: ProcessExit?
        var reaped = false
        var readingFinished = false
        init(pid: pid_t, pgid: pid_t, stdoutRead: FileHandle, stderrRead: FileHandle) {
            self.pid = pid
            self.pgid = pgid
            self.stdoutRead = stdoutRead
            self.stderrRead = stderrRead
        }
    }

    private let lock = NSLock()
    private let logFileURL: URL
    private let maxStderrLines: Int
    private let killGraceSeconds: Double
    private let rotation: LogRotationPolicy
    private var nextRaw: UInt64 = 1
    private var entries: [ProcessHandleID: Entry] = [:]
    private var latestPID: pid_t?

    // One shared, size rotated log for the runner's stdout and stderr.
    private var logHandle: FileHandle?
    private var logBytes: Int = 0

    init(logFileURL: URL,
         maxStderrLines: Int = 200,
         killGraceSeconds: Double = 3,
         rotation: LogRotationPolicy = LogRotationPolicy(maxBytes: 5_000_000, keepFiles: 3)) {
        self.logFileURL = logFileURL
        self.maxStderrLines = maxStderrLines
        self.killGraceSeconds = killGraceSeconds
        self.rotation = rotation
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        openLogLocked()
    }

    func spawn(_ spec: ProcessSpec) throws -> ProcessHandleID {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in spec.environmentOverrides {
            environment[key] = value
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errWrite = stderrPipe.fileHandleForWriting.fileDescriptor

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errWrite, STDERR_FILENO)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Give the runner a clean signal state. Hearth sets SIGTERM/SIGINT/SIGHUP
        // to SIG_IGN and libdispatch leaves them blocked for its signal sources;
        // both survive across spawn and exec. Without resetting, the runner starts
        // with our SIGTERM ignored or blocked and would not die from Hearth's
        // graceful teardown, only the SIGKILL backup. Reset the relevant signals to
        // their default disposition, and clear the inherited blocked mask entirely.
        var resetSignals = sigset_t()
        sigemptyset(&resetSignals)
        sigaddset(&resetSignals, SIGTERM)
        sigaddset(&resetSignals, SIGINT)
        sigaddset(&resetSignals, SIGHUP)
        posix_spawnattr_setsigdefault(&attr, &resetSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        // New process group led by the child (pgroup 0), signals reset and
        // unblocked, and every inherited fd closed except the ones we dup, so none
        // of Hearth's fds leak to the runner.
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
            | Int16(POSIX_SPAWN_SETSIGDEF)
            | Int16(POSIX_SPAWN_SETSIGMASK)
            | Int16(bitPattern: UInt16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        let path = spec.executableURL.path
        let argv = [path] + spec.arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let rc = withCStringArray(argv) { argvPtr in
            withCStringArray(envp) { envpPtr in
                path.withCString { pathPtr in
                    posix_spawn(&pid, pathPtr, &fileActions, &attr, argvPtr, envpPtr)
                }
            }
        }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)

        // The child holds the write ends now; the parent only reads.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        guard rc == 0, pid > 0 else {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw SpawnError(code: rc)
        }

        let entry = Entry(
            pid: pid,
            pgid: pid, // child is the group leader, so the group id equals its pid
            stdoutRead: stdoutPipe.fileHandleForReading,
            stderrRead: stderrPipe.fileHandleForReading
        )

        let id: ProcessHandleID = lock.withLock {
            let handle = ProcessHandleID(raw: nextRaw)
            nextRaw += 1
            entries[handle] = entry
            latestPID = pid
            let banner = "\n=== spawn \(spec.executableURL.lastPathComponent) \(spec.arguments.joined(separator: " ")) ===\n"
            appendLogLocked(Data(banner.utf8))
            return handle
        }

        // Record this runner so a hard SIGKILL of Hearth can be recovered from on
        // the next launch (the child is its own process group leader).
        RunnerStateStore.record(pid: pid, pgid: pid)

        entry.stdoutRead.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.lock.withLock { self?.appendLogLocked(data) }
        }
        entry.stderrRead.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.ingestStderr(id, data: data)
        }

        return id
    }

    func status(_ id: ProcessHandleID) -> ProcessStatus {
        lock.withLock {
            guard let entry = entries[id] else {
                return ProcessStatus(isAlive: false)
            }
            if let exit = entry.exit {
                return ProcessStatus(isAlive: false, exit: exit, recentStderr: entry.stderrRing)
            }
            // Reap non-blocking. A stopped (SIGSTOP wedged) child reports no change
            // here, so it is correctly seen as alive while readiness catches it.
            var raw: Int32 = 0
            let result = waitpid(entry.pid, &raw, WNOHANG)
            if result == 0 {
                return ProcessStatus(isAlive: true, exit: nil, recentStderr: entry.stderrRing)
            }
            let exit = result == entry.pid ? Self.decode(raw) : ProcessExit(code: 0, wasSignaled: true, signal: SIGKILL)
            entry.exit = exit
            entry.reaped = true
            finishReading(entry)
            // The child is gone; do not report its (possibly recycled) PID's memory.
            if latestPID == entry.pid { latestPID = nil }
            return ProcessStatus(isAlive: false, exit: exit, recentStderr: entry.stderrRing)
        }
    }

    func terminate(_ id: ProcessHandleID) {
        let entry: Entry? = lock.withLock { entries[id] }
        guard let entry, entry.pgid > 1 else {
            // Nothing live to signal; just forget any stale entry.
            lock.withLock { _ = entries.removeValue(forKey: id) }
            return
        }
        let pgid = entry.pgid
        let pid = entry.pid
        // Stop reading the doomed child and release its pipe fds now, rather than
        // leaking the handlers and descriptors until something probes it again.
        lock.withLock { finishReading(entry) }
        // Take the whole runner tree down: serve plus the llama-server grandchild.
        killpg(pgid, SIGTERM)
        let grace = killGraceSeconds
        // Capture self strongly: on a config reload the controller can be replaced
        // and released within this grace window, and a weak ref would skip the
        // reap, leaving the SIGKILLed leader a zombie until Hearth itself exits.
        // The closure runs once and is then released, so this only extends the
        // old controller's life by `grace`, with no retain cycle.
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            // SIGKILL the group if anything in it is still alive (a wedged or
            // SIGSTOPped runner ignores SIGTERM; SIGKILL still lands).
            if killpg(pgid, 0) == 0 {
                killpg(pgid, SIGKILL)
            }
            // Reap the group leader so it is not left a zombie, and forget the
            // entry so the dictionary does not grow with every restart.
            reapAndRemove(id: id, pid: pid)
        }
    }

    /// Reap a terminated leader and drop its entry. Safe if it was already reaped
    /// by a `status` probe; reaps outside the lock so a slow wait cannot stall it.
    private func reapAndRemove(id: ProcessHandleID, pid: pid_t) {
        let needsReap: Bool = lock.withLock {
            guard let entry = entries[id] else { return false }
            return !entry.reaped
        }
        if needsReap {
            var raw: Int32 = 0
            _ = waitpid(pid, &raw, 0)   // the group SIGKILL has landed, so this returns at once
        }
        lock.withLock {
            if let entry = entries[id] {
                entry.reaped = true
                finishReading(entry)
                entries.removeValue(forKey: id)
            }
            if latestPID == pid { latestPID = nil }
        }
    }

    /// Size, modification time, and inode of the executable on disk. `stat`
    /// follows symlinks, so a Homebrew binary fingerprints its Cellar target,
    /// whose inode changes when `brew upgrade` relinks it.
    func executableFingerprint(at url: URL) -> String? {
        var info = stat()
        let result = url.path.withCString { stat($0, &info) }
        guard result == 0 else { return nil }
        return "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ino)"
    }

    /// Resident size of the most recently spawned child, for the metrics readout.
    func latestResidentBytes() -> Int64? {
        let pid: pid_t? = lock.withLock { latestPID }
        guard let pid else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard written == size else { return nil }
        return Int64(info.pti_resident_size)
    }

    // MARK: - Exit decoding

    /// Decode a waitpid status into our exit model. Mirrors WIFEXITED / WTERMSIG.
    private static func decode(_ status: Int32) -> ProcessExit {
        if status & 0x7f == 0 {
            return ProcessExit(code: (status >> 8) & 0xff, wasSignaled: false, signal: nil)
        }
        return ProcessExit(code: 0, wasSignaled: true, signal: status & 0x7f)
    }

    private func finishReading(_ entry: Entry) {
        guard !entry.readingFinished else { return }
        entry.readingFinished = true
        entry.stdoutRead.readabilityHandler = nil
        entry.stderrRead.readabilityHandler = nil
        if !entry.partialStderr.isEmpty, let line = String(data: entry.partialStderr, encoding: .utf8) {
            entry.stderrRing.append(line)
            entry.partialStderr.removeAll()
        }
        try? entry.stdoutRead.close()
        try? entry.stderrRead.close()
    }

    // MARK: - stderr ring

    private func ingestStderr(_ id: ProcessHandleID, data: Data) {
        lock.withLock {
            appendLogLocked(data)
            guard let entry = entries[id] else { return }
            entry.partialStderr.append(data)
            while let newline = entry.partialStderr.firstIndex(of: 0x0A) {
                let lineData = entry.partialStderr[entry.partialStderr.startIndex..<newline]
                entry.partialStderr.removeSubrange(entry.partialStderr.startIndex...newline)
                appendStderrLine(lineData, to: entry)
            }
            // Cap a runaway no-newline line so the partial buffer cannot grow
            // without bound (a runner that floods stderr with no newline).
            let maxPartialBytes = 64 * 1024
            if entry.partialStderr.count > maxPartialBytes {
                appendStderrLine(entry.partialStderr[...], to: entry)
                entry.partialStderr.removeAll(keepingCapacity: false)
            }
        }
    }

    private func appendStderrLine(_ lineData: Data.SubSequence, to entry: Entry) {
        guard let line = String(data: lineData, encoding: .utf8) else { return }
        entry.stderrRing.append(line)
        if entry.stderrRing.count > maxStderrLines {
            entry.stderrRing.removeFirst(entry.stderrRing.count - maxStderrLines)
        }
    }

    // MARK: - Log writing and rotation (lock held by callers)

    private func openLogLocked() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logFileURL)
        logHandle?.seekToEndOfFile()
        let attributes = try? fm.attributesOfItem(atPath: logFileURL.path)
        logBytes = (attributes?[.size] as? Int) ?? 0
    }

    private func appendLogLocked(_ data: Data) {
        logHandle?.write(data)
        logBytes += data.count
        if rotation.shouldRotate(currentBytes: logBytes) {
            rotateLocked()
        }
    }

    private func rotateLocked() {
        let fm = FileManager.default
        try? logHandle?.close()
        logHandle = nil
        for step in rotation.steps(forBase: logFileURL.path) {
            switch step {
            case .delete(let path):
                try? fm.removeItem(atPath: path)
            case .move(let from, let to):
                guard fm.fileExists(atPath: from) else { continue }
                try? fm.removeItem(atPath: to)
                try? fm.moveItem(atPath: from, toPath: to)
            }
        }
        openLogLocked()
        logBytes = 0
    }

    private func withCStringArray<R>(_ values: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return pointers.withUnsafeBufferPointer { buffer in body(buffer.baseAddress!) }
    }
}
