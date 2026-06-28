// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Runs supervision with no GUI, for a pre login root LaunchDaemon on a truly
/// headless Mac where no one logs in. There is no menubar and no local
/// Notification Center (there is no session to show it); ntfy still reaches a
/// phone, and the control endpoint and the power assertion work the same.
final class HeadlessRunner {
    private let config: HearthConfig
    private let assembly: SupervisorAssembly
    private var signalSources: [DispatchSourceSignal] = []

    init(config: HearthConfig) {
        self.config = config
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

        // Persist supervisor events so `hearth events` and the next launch can see
        // the history; nothing else consumes the event stream when headless.
        let events = assembly.engine.events
        Task { for await event in events { EventLogStore.append(event) } }

        // Reboot escalation (opt-in, root only): when a wedge survives process
        // restarts for long enough, escalate to a reboot. Only wired headless,
        // since the GUI app is not root and cannot reboot.
        let rebootPolicy = config.rebootPolicy()
        if rebootPolicy.enabled {
            let notifier = assembly.notifier
            let escalator = RebootEscalator(policy: rebootPolicy, system: SystemController()) { message in
                FileHandle.standardError.write(Data("Hearth headless: \(message)\n".utf8))
                Task.detached {
                    await notifier.notify(HearthNotification(
                        level: .critical, title: "Hearth recovery", body: message, event: .down(.wedged)))
                }
            }
            let states = assembly.engine.states
            Task { for await state in states { escalator.observe(state) } }
        }

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
                // The engine sent SIGTERM; ensure a wedged child is actually dead
                // before we exit, rather than relying on a deferred SIGKILL that
                // exit() would outrun.
                RunnerStateStore.killRecordedGroupNow()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
