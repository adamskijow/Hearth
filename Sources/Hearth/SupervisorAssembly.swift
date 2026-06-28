// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Builds the supervisor stack (engine, coordinator, control server, metrics)
/// from config, so the menubar app and the headless daemon share one wiring.
struct SupervisorAssembly {
    let engine: SupervisorEngine
    let coordinator: SupervisionCoordinator
    let controlServer: ControlServer?
    let metricsProvider: SystemMetricsProvider
    let processController: FoundationProcessController
    let runner: any Runner

    /// `includeLocalNotifications` is false in headless mode, where there is no
    /// GUI session for the local Notification Center to reach.
    static func make(config: HearthConfig, includeLocalNotifications: Bool) -> SupervisorAssembly {
        let processController = FoundationProcessController(
            logFileURL: AppPaths.runnerLogFile,
            rotation: config.logRotationPolicy()
        )
        let metricsProvider = SystemMetricsProvider(runnerResidentBytes: { [weak processController] in
            processController?.latestResidentBytes()
        })
        let runner = config.makeRunner()

        let engine = SupervisorEngine(
            clock: SystemClock(),
            processes: processController,
            http: URLSessionHTTPClient(),
            runner: runner,
            power: IOKitPowerManager(),
            notifier: makeNotifier(config: config, includeLocal: includeLocalNotifications),
            policy: config.policy(),
            managed: config.isManaged
        )
        let coordinator = SupervisionCoordinator(engine: engine)

        var controlServer: ControlServer?
        if config.controlEnabled, let token = config.controlToken, !token.isEmpty {
            controlServer = ControlServer(
                host: config.controlHost,
                port: config.controlPort,
                token: token,
                coordinator: coordinator,
                metrics: metricsProvider
            )
        }

        return SupervisorAssembly(
            engine: engine,
            coordinator: coordinator,
            controlServer: controlServer,
            metricsProvider: metricsProvider,
            processController: processController,
            runner: runner
        )
    }

    private static func makeNotifier(config: HearthConfig, includeLocal: Bool) -> Notifier {
        var notifiers: [Notifier] = []
        if includeLocal, config.localNotifications {
            notifiers.append(LocalNotifier())
        }
        if let topic = config.ntfyTopic, !topic.trimmingCharacters(in: .whitespaces).isEmpty {
            notifiers.append(NtfyNotifier(server: config.ntfyServer, topic: topic))
        }
        return CompositeNotifier(notifiers)
    }
}
