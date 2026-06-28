// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Runs supervision with no GUI, for a pre login root LaunchDaemon on a truly
/// headless Mac where no one logs in. There is no menubar and no local
/// Notification Center (there is no session to show it); ntfy still reaches a
/// phone, and the control endpoint and the power assertion work the same.
final class HeadlessRunner {
    private let assembly: SupervisorAssembly
    private var signalSources: [DispatchSourceSignal] = []

    init(config: HearthConfig) {
        assembly = .make(config: config, includeLocalNotifications: false)
    }

    /// Start supervising and block forever servicing the main queue. Returns only
    /// when a signal handler calls exit.
    func run() -> Never {
        let mode = assembly.runner.name
        FileHandle.standardError.write(Data("Hearth headless: supervising \(mode)\n".utf8))

        // Recover from a previous hard crash before starting a new runner.
        if let swept = RunnerStateStore.sweepOrphan() {
            FileHandle.standardError.write(Data("Hearth headless: \(swept)\n".utf8))
        }

        assembly.controlServer?.start()
        installSignalHandlers()

        let coordinator = assembly.coordinator
        Task { await coordinator.begin() }

        dispatchMain()
    }

    private func installSignalHandlers() {
        let coordinator = assembly.coordinator
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // Stop cleanly (kill the child, release power), then exit.
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    await coordinator.end()
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 2)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
