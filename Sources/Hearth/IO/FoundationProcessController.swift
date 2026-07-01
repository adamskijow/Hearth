// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore
import HearthSpawn

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
/// Thread safe by a lock: pipe read sources fire on a background queue, while
/// the engine calls `status` from its actor.
final class FoundationProcessController: ProcessControlling, @unchecked Sendable {
    private final class Entry {
        let pid: pid_t
        let pgid: pid_t
        let stdoutRead: FileHandle
        let stderrRead: FileHandle
        /// The leader's identity (pid plus start time) captured at spawn, so the
        /// deferred group SIGKILL can re-validate that the pgid still names this
        /// child before signalling, and the crash-recovery record can be dropped
        /// precisely once the reap is confirmed.
        let spawnIdentity: RunnerProcessIdentity?
        /// Pipe drain sources. Each source's cancellation handler owns the close
        /// of its file descriptor, so a read can never race a close (GCD runs the
        /// cancel handler only after any in-flight event handler returns, and no
        /// event handler runs after it).
        var stdoutSource: DispatchSourceRead?
        var stderrSource: DispatchSourceRead?
        var stderrRing: [String] = []
        var stderr = StderrLineSplitter()
        var exit: ProcessExit?
        var reaped = false
        var readingFinished = false
        init(pid: pid_t, pgid: pid_t, stdoutRead: FileHandle, stderrRead: FileHandle,
             spawnIdentity: RunnerProcessIdentity?) {
            self.pid = pid
            self.pgid = pgid
            self.stdoutRead = stdoutRead
            self.stderrRead = stderrRead
            self.spawnIdentity = spawnIdentity
        }
    }

    private let lock = NSLock()
    /// One serial queue drains every child's pipes. Serial so an entry's event
    /// handlers and its cancellation handlers (which close the fds) are mutually
    /// exclusive by construction.
    private let readQueue = DispatchQueue(label: "Hearth.FoundationProcessController.pipe-read")
    private let logFileURL: URL
    private let maxStderrLines: Int
    private let killGraceSeconds: Double
    private let rotation: LogRotationPolicy
    /// The account the spawned runner is dropped to, when configured (`runnerUser`)
    /// and Hearth is root. Root without a non-root runnerUser refuses to spawn; the
    /// ordinary `posix_spawn` path is for the non-root app and login agent.
    private let runAsUser: String?
    private let dropCredentials: RunnerUserCredentials?
    private var nextRaw: UInt64 = 1
    private var entries: [ProcessHandleID: Entry] = [:]
    private var latestPID: pid_t?

    // One shared, size rotated log for the runner's stdout and stderr.
    private var logHandle: FileHandle?
    private var logBytes: Int = 0

    init(logFileURL: URL,
         maxStderrLines: Int = 200,
         killGraceSeconds: Double = 3,
         rotation: LogRotationPolicy = LogRotationPolicy(maxBytes: 5_000_000, keepFiles: 3),
         runAsUser: String? = nil) {
        self.logFileURL = logFileURL
        self.maxStderrLines = maxStderrLines
        self.killGraceSeconds = killGraceSeconds
        self.rotation = rotation
        self.runAsUser = runAsUser
        self.dropCredentials = runAsUser.flatMap { RunnerUserCredentials.resolve(username: $0) }
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        openLogLocked()
        if let user = runAsUser {
            if dropCredentials == nil {
                warn("runnerUser \"\(user)\" does not resolve to an account; as root the runner will refuse to start rather than run as root")
            } else if dropCredentials?.isRoot == true {
                warn("runnerUser \"\(user)\" resolves to root; as root the runner will refuse to start rather than keep root privileges")
            } else if geteuid() != 0 {
                warn("runnerUser \"\(user)\" is set but Hearth is not root; the runner inherits this user, no privilege drop")
            }
        } else if geteuid() == 0 {
            warn("runnerUser is unset; as root Hearth will refuse to start a managed runner rather than run it as root")
        }
    }

    deinit {
        // A read source's event handler references the source, a deliberate cycle
        // that cancellation breaks. If a controller is ever dropped with entries
        // still tracked, cancel their sources so the descriptors and sources are
        // not leaked for the rest of the process's life.
        for entry in entries.values {
            finishReading(entry)
        }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("Hearth: \(message)\n".utf8))
    }

    func spawn(_ spec: ProcessSpec) throws -> ProcessHandleID {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in spec.environmentOverrides {
            environment[key] = value
        }
        // When dropping the runner to another user, supply that account's
        // HOME/USER/LOGNAME. A LaunchDaemon runs with no HOME, and Ollama refuses to
        // start without one ("Error: $HOME is not defined"). The config's runnerEnv
        // still wins, so an explicit HOME override is respected.
        if geteuid() == 0, let credentials = dropCredentials {
            for (key, value) in [("HOME", credentials.home), ("USER", credentials.name), ("LOGNAME", credentials.name)]
            where spec.environmentOverrides[key] == nil && !value.isEmpty {
                environment[key] = value
            }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errWrite = stderrPipe.fileHandleForWriting.fileDescriptor

        let pid: pid_t
        do {
            if geteuid() == 0, let credentials = dropCredentials, !credentials.isRoot {
                // Root daemon with a resolved runnerUser: fork and drop privileges
                // so the runner runs unprivileged. Hearth (the parent) stays root so
                // it keeps the reboot capability.
                pid = try forkExecAsUser(spec: spec, environment: environment,
                                         credentials: credentials, outWrite: outWrite, errWrite: errWrite)
            } else if geteuid() == 0 {
                // Root without a non-root runnerUser would run the untrusted
                // runner as root. Fail closed: the root daemon must either drop to
                // an unprivileged account or use attached mode.
                throw SpawnError(code: EPERM)
            } else {
                // The default, unchanged path: the runner inherits Hearth's user.
                pid = try posixSpawnChild(spec: spec, environment: environment,
                                          outWrite: outWrite, errWrite: errWrite)
            }
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw error
        }

        // The child holds the write ends now; the parent only reads.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // Record this runner so a hard SIGKILL of Hearth can be recovered from on
        // the next launch (the child is its own process group leader). The captured
        // identity also guards this entry's deferred group SIGKILL against a
        // recycled pgid, and is removed from the record once the reap is confirmed.
        let spawnIdentity = RunnerStateStore.record(pid: pid, pgid: pid)

        let entry = Entry(
            pid: pid,
            pgid: pid, // child is the group leader, so the group id equals its pid
            stdoutRead: stdoutPipe.fileHandleForReading,
            stderrRead: stderrPipe.fileHandleForReading,
            spawnIdentity: spawnIdentity
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

        entry.stdoutSource = makeReadSource(draining: entry.stdoutRead) { [weak self] data in
            guard let self else { return }
            self.lock.withLock { self.appendLogLocked(data) }
        }
        entry.stderrSource = makeReadSource(draining: entry.stderrRead) { [weak self] data in
            self?.ingestStderr(id, data: data)
        }

        return id
    }

    /// Drain one pipe end with a `DispatchSourceRead`. The source's cancellation
    /// handler owns the close of the descriptor: GCD guarantees the cancel handler
    /// runs only after any in-flight event handler has returned and that no event
    /// handler runs after it, so a `read` can never touch a closed fd. That
    /// mutual exclusion is the point; the previous `readabilityHandler` approach
    /// called `availableData` (which raises an uncatchable NSException on a closed
    /// fd) in a race with `finishReading`'s close on the restart hot path.
    private func makeReadSource(draining handle: FileHandle,
                                onData: @escaping (Data) -> Void) -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                onData(Data(bytes: buffer, count: count))
            } else if !(count == -1 && (errno == EAGAIN || errno == EINTR)) {
                // EOF (the child closed its end) or a real error: stop reading and
                // close the fd via the cancellation handler.
                source.cancel()
            }
        }
        // The handler keeps the FileHandle alive until cancellation, and closing
        // here is the only close, so the fd cannot be double closed or recycled
        // under a pending read.
        source.setCancelHandler {
            try? handle.close()
        }
        source.resume()
        return source
    }

    /// The default spawn: the runner inherits Hearth's user. posix_spawn in a new
    /// process group with SIGTERM/SIGINT/SIGHUP reset to default, the inherited mask
    /// cleared, stdout/stderr on the pipes, and every other inherited fd closed.
    /// Throws SpawnError on failure. Used by the non-root app and login agent; the
    /// root daemon reaches this only after the root-specific checks refuse to run
    /// an untrusted runner as root.
    private func posixSpawnChild(spec: ProcessSpec,
                                 environment: [String: String],
                                 outWrite: Int32,
                                 errWrite: Int32) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errWrite, STDERR_FILENO)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        var resetSignals = sigset_t()
        sigemptyset(&resetSignals)
        sigaddset(&resetSignals, SIGTERM)
        sigaddset(&resetSignals, SIGINT)
        sigaddset(&resetSignals, SIGHUP)
        posix_spawnattr_setsigdefault(&attr, &resetSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
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

        guard rc == 0, pid > 0 else { throw SpawnError(code: rc) }
        return pid
    }

    /// Spawn the runner as `credentials` (only the root daemon reaches this).
    /// macOS posix_spawn cannot set the uid, so this delegates to a C shim that
    /// forks and drops privileges in the child (see Sources/HearthSpawn). The C
    /// arrays it needs, argv/envp and the group list, are materialized here first so
    /// the shim's child does no allocation. Throws SpawnError on fork failure.
    private func forkExecAsUser(spec: ProcessSpec,
                                environment: [String: String],
                                credentials: RunnerUserCredentials,
                                outWrite: Int32,
                                errWrite: Int32) throws -> pid_t {
        let path = spec.executableURL.path
        let argv = [path] + spec.arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        let pid: pid_t = path.withCString { pathPtr in
            withCStringArray(argv) { argvPtr in
                withCStringArray(envp) { envpPtr in
                    credentials.supplementaryGroups.withUnsafeBufferPointer { groupsPtr in
                        hearth_spawn_as_user(pathPtr, argvPtr, envpPtr, outWrite, errWrite,
                                             credentials.uid, credentials.gid,
                                             groupsPtr.baseAddress, Int32(groupsPtr.count))
                    }
                }
            }
        }
        guard pid > 0 else { throw SpawnError(code: errno) }
        return pid
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
            let exit = result == entry.pid ? ProcessExit.from(waitpidStatus: raw) : ProcessExit(code: 0, wasSignaled: true, signal: SIGKILL)
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
        let spawnIdentity = entry.spawnIdentity
        // Stop reading the doomed child and release its pipe fds now, rather than
        // leaking the sources and descriptors until something probes it again.
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
            // SIGSTOPped runner ignores SIGTERM; SIGKILL still lands), but only
            // while the group id provably still belongs to this child: once the
            // leader has been reaped its pid (== pgid) can be recycled, and a
            // blind killpg here could SIGKILL an unrelated group that inherited
            // the number inside the grace window. An unreaped leader (alive or
            // zombie) keeps the pgid reserved, so signalling stays safe; on top
            // of that the leader's start time is re-checked against the identity
            // captured at spawn whenever it is still probeable.
            let leaderReaped: Bool = lock.withLock {
                guard let entry = entries[id] else { return true }
                return entry.reaped
            }
            if RunnerSweep.deferredKillAllowed(leaderReaped: leaderReaped,
                                               spawn: spawnIdentity,
                                               live: RunnerStateStore.liveIdentity(pid: pid)),
               killpg(pgid, 0) == 0 {
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
        let reapedIdentity: RunnerProcessIdentity? = lock.withLock {
            var identity: RunnerProcessIdentity?
            if let entry = entries[id] {
                entry.reaped = true
                finishReading(entry)
                entries.removeValue(forKey: id)
                identity = entry.spawnIdentity
            }
            if latestPID == pid { latestPID = nil }
            return identity
        }
        // The reap is confirmed: the pid can be recycled from here on and the
        // record is no longer sweepable (the sweep is keyed on the leader's
        // identity), so drop it from the crash-recovery set.
        if let reapedIdentity {
            RunnerStateStore.remove(reapedIdentity)
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

    // MARK: - stderr ring

    private func finishReading(_ entry: Entry) {
        guard !entry.readingFinished else { return }
        entry.readingFinished = true
        // Cancelling is asynchronous and idempotent: the close happens in each
        // source's cancellation handler on the read queue, strictly after any
        // in-flight read, so this is safe to call while a drain is running.
        entry.stdoutSource?.cancel()
        entry.stderrSource?.cancel()
        if let line = entry.stderr.flush() { appendStderrLine(line, to: entry) }
    }

    private func ingestStderr(_ id: ProcessHandleID, data: Data) {
        lock.withLock {
            appendLogLocked(data)
            guard let entry = entries[id] else { return }
            for line in entry.stderr.ingest(data) {
                appendStderrLine(line, to: entry)
            }
        }
    }

    private func appendStderrLine(_ line: String, to entry: Entry) {
        entry.stderrRing.append(line)
        if entry.stderrRing.count > maxStderrLines {
            entry.stderrRing.removeFirst(entry.stderrRing.count - maxStderrLines)
        }
    }

    // MARK: - Log writing and rotation (lock held by callers)

    private func openLogLocked() {
        let fm = FileManager.default
        SecureFile.prepareFile(logFileURL)
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
