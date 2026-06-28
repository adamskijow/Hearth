// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// posix_spawn failed with this non-zero return code.
struct SpawnError: Error { let code: Int32 }

/// The real process controller. It spawns the runner with `posix_spawn` in a NEW
/// process group (the child becomes the group leader), captures stdout and stderr
/// to a log file, keeps a ring of recent stderr for exit classification, and on
/// teardown kills the WHOLE group with `killpg`.
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
        var logHandle: FileHandle?
        var exit: ProcessExit?
        var reaped = false
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
    private var nextRaw: UInt64 = 1
    private var entries: [ProcessHandleID: Entry] = [:]
    private var latestPID: pid_t?

    init(logFileURL: URL, maxStderrLines: Int = 200, killGraceSeconds: Double = 3) {
        self.logFileURL = logFileURL
        self.maxStderrLines = maxStderrLines
        self.killGraceSeconds = killGraceSeconds
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
        // New process group led by the child (pgroup 0), and close every inherited
        // fd except the ones we dup above, so none of Hearth's fds leak to ollama.
        let flags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(bitPattern: UInt16(POSIX_SPAWN_CLOEXEC_DEFAULT))
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
            entry.logHandle = openLog(for: spec)
            entries[handle] = entry
            latestPID = pid
            return handle
        }

        entry.stdoutRead.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.writeLog(id, data: data)
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
            // Exited (or already gone): record the exit and stop reading.
            let exit = result == entry.pid ? Self.decode(raw) : ProcessExit(code: 0, wasSignaled: true, signal: SIGKILL)
            entry.exit = exit
            entry.reaped = true
            finishReading(entry)
            return ProcessStatus(isAlive: false, exit: exit, recentStderr: entry.stderrRing)
        }
    }

    func terminate(_ id: ProcessHandleID) {
        let pgid: pid_t? = lock.withLock { entries[id]?.pgid }
        guard let pgid, pgid > 1 else { return }
        // Take the whole runner tree down: serve plus the llama-server grandchild.
        killpg(pgid, SIGTERM)
        let grace = killGraceSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            // SIGKILL the group if anything in it is still alive (a wedged or
            // SIGSTOPped runner ignores SIGTERM; SIGKILL still lands).
            if killpg(pgid, 0) == 0 {
                killpg(pgid, SIGKILL)
            }
        }
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

    // MARK: - Helpers

    /// Decode a waitpid status into our exit model. Mirrors WIFEXITED / WTERMSIG.
    private static func decode(_ status: Int32) -> ProcessExit {
        if status & 0x7f == 0 {
            return ProcessExit(code: (status >> 8) & 0xff, wasSignaled: false, signal: nil)
        }
        return ProcessExit(code: 0, wasSignaled: true, signal: status & 0x7f)
    }

    private func finishReading(_ entry: Entry) {
        entry.stdoutRead.readabilityHandler = nil
        entry.stderrRead.readabilityHandler = nil
        if !entry.partialStderr.isEmpty, let line = String(data: entry.partialStderr, encoding: .utf8) {
            entry.stderrRing.append(line)
            entry.partialStderr.removeAll()
        }
        try? entry.stdoutRead.close()
        try? entry.stderrRead.close()
        try? entry.logHandle?.close()
        entry.logHandle = nil
    }

    private func openLog(for spec: ProcessSpec) -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return nil }
        handle.seekToEndOfFile()
        let banner = "\n=== spawn \(spec.executableURL.lastPathComponent) \(spec.arguments.joined(separator: " ")) ===\n"
        handle.write(Data(banner.utf8))
        return handle
    }

    private func writeLog(_ id: ProcessHandleID, data: Data) {
        lock.withLock { entries[id]?.logHandle?.write(data) }
    }

    private func ingestStderr(_ id: ProcessHandleID, data: Data) {
        lock.withLock {
            guard let entry = entries[id] else { return }
            entry.logHandle?.write(data)
            entry.partialStderr.append(data)
            while let newline = entry.partialStderr.firstIndex(of: 0x0A) {
                let lineData = entry.partialStderr[entry.partialStderr.startIndex..<newline]
                entry.partialStderr.removeSubrange(entry.partialStderr.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    entry.stderrRing.append(line)
                    if entry.stderrRing.count > maxStderrLines {
                        entry.stderrRing.removeFirst(entry.stderrRing.count - maxStderrLines)
                    }
                }
            }
        }
    }

    private func withCStringArray<R>(_ values: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return pointers.withUnsafeBufferPointer { buffer in body(buffer.baseAddress!) }
    }
}
