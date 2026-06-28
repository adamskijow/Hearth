// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// The real process controller, driving `Foundation.Process`. It owns the child,
/// merges the spec's environment overrides on top of the parent environment at
/// spawn (the managed mode contract), captures stdout and stderr to a log file,
/// and keeps a small ring of recent stderr lines for exit classification.
///
/// Thread safe by a lock: process readability and termination handlers fire on
/// arbitrary background queues, while the engine calls `status` from its actor.
final class FoundationProcessController: ProcessControlling, @unchecked Sendable {
    private final class Entry {
        let process: Process
        var stderrRing: [String] = []
        var exit: ProcessExit?
        var logHandle: FileHandle?
        var partialStderr = Data()
        init(process: Process) { self.process = process }
    }

    private let lock = NSLock()
    private let logFileURL: URL
    private let maxStderrLines: Int
    private var nextRaw: UInt64 = 1
    private var entries: [ProcessHandleID: Entry] = [:]
    private var latestPID: pid_t?

    init(logFileURL: URL, maxStderrLines: Int = 200) {
        self.logFileURL = logFileURL
        self.maxStderrLines = maxStderrLines
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func spawn(_ spec: ProcessSpec) throws -> ProcessHandleID {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments

        // Merge overrides onto the inherited environment. This is where managed
        // mode pins OLLAMA_HOST, dodging the launchd env trap.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in spec.environmentOverrides {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let id: ProcessHandleID = lock.withLock {
            let handle = ProcessHandleID(raw: nextRaw)
            nextRaw += 1
            let entry = Entry(process: process)
            entry.logHandle = openLog(for: spec)
            entries[handle] = entry
            return handle
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.writeLog(id, data: data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingestStderr(id, data: data)
        }
        process.terminationHandler = { [weak self] proc in
            self?.recordExit(id, process: proc)
        }

        do {
            try process.run()
            lock.withLock { latestPID = process.processIdentifier }
        } catch {
            lock.withLock { entries[id] = nil }
            throw error
        }
        return id
    }

    /// Resident size of the most recently spawned child, for the metrics readout.
    /// Returns nil once it has exited.
    func latestResidentBytes() -> Int64? {
        let pid: pid_t? = lock.withLock { latestPID }
        guard let pid else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard written == size else { return nil }
        return Int64(info.pti_resident_size)
    }

    func status(_ id: ProcessHandleID) -> ProcessStatus {
        lock.withLock {
            guard let entry = entries[id] else {
                return ProcessStatus(isAlive: false)
            }
            let alive = entry.process.isRunning
            if alive {
                return ProcessStatus(isAlive: true, exit: nil, recentStderr: entry.stderrRing)
            }
            // Not running: prefer the handler recorded exit, but synthesize from
            // the process itself if the handler has not fired yet, so a death is
            // never misread as still running.
            let exit = entry.exit ?? Self.exit(from: entry.process)
            return ProcessStatus(isAlive: false, exit: exit, recentStderr: entry.stderrRing)
        }
    }

    func terminate(_ id: ProcessHandleID) {
        let process: Process? = lock.withLock { entries[id]?.process }
        guard let process, process.isRunning else { return }
        process.terminate() // SIGTERM

        // If it ignores SIGTERM (a truly wedged runner can), follow up with
        // SIGKILL so a zombie cannot linger and block the next spawn.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Helpers

    private static func exit(from process: Process) -> ProcessExit {
        let signaled = process.terminationReason == .uncaughtSignal
        let status = process.terminationStatus
        return ProcessExit(
            code: status,
            wasSignaled: signaled,
            signal: signaled ? status : nil
        )
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
            // Split complete lines off the buffer into the ring.
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

    private func recordExit(_ id: ProcessHandleID, process: Process) {
        lock.withLock {
            guard let entry = entries[id] else { return }
            entry.exit = Self.exit(from: process)
            // Flush any trailing partial stderr line.
            if !entry.partialStderr.isEmpty,
               let line = String(data: entry.partialStderr, encoding: .utf8) {
                entry.stderrRing.append(line)
                entry.partialStderr.removeAll()
            }
            try? entry.logHandle?.close()
            entry.logHandle = nil
        }
    }
}
