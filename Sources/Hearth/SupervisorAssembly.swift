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
    let notifier: ReloadableNotifier
    let pressureMonitor: PressureMonitor
    let heartbeat: HeartbeatPinger?
    let metricsProxy: MetricsProxy?
    let tokenMetrics: TokenMetricsStore?

    /// `includeLocalNotifications` is false in headless mode, where there is no
    /// GUI session for the local Notification Center to reach.
    static func make(config: HearthConfig, includeLocalNotifications: Bool) -> SupervisorAssembly {
        let processController = FoundationProcessController(
            logFileURL: AppPaths.runnerLogFile,
            rotation: config.logRotationPolicy(),
            runAsUser: config.normalizedRunnerUser
        )
        let metricsProvider = SystemMetricsProvider(runnerResidentBytes: { [weak processController] in
            processController?.latestResidentBytes()
        })
        let runner = config.makeRunner()
        let notifier = ReloadableNotifier(
            notificationChannels(config: config, includeLocal: includeLocalNotifications))

        // The opt-in tokens-per-second tap. The proxy listens where the runner
        // does (same host semantics) and relays to it; the store feeds /metrics,
        // and its in-flight count feeds the graceful-drain gate.
        var metricsProxy: MetricsProxy?
        var tokenMetrics: TokenMetricsStore?
        if config.metricsProxyEnabled {
            let store = TokenMetricsStore()
            metricsProxy = MetricsProxy(
                host: config.host,
                port: config.metricsProxyPort,
                upstreamHost: probeHost(for: config.host),
                upstreamPort: config.port,
                store: store
            )
            tokenMetrics = metricsProxy == nil ? nil : store
        }

        var inFlight: (@Sendable () -> Int)?
        if let proxy = metricsProxy {
            inFlight = { [weak proxy] in proxy?.inFlightConnections() ?? 0 }
        }
        let engine = SupervisorEngine(
            clock: SystemClock(),
            processes: processController,
            http: URLSessionHTTPClient(),
            runner: runner,
            power: IOKitPowerManager(),
            notifier: notifier,
            policy: config.policy(),
            managed: config.isManaged,
            deepProbe: config.deepProbe(),
            warmModels: config.warmModelsAfterRestart,
            memoryLimitBytes: Int64(max(0, config.runnerMemoryLimitMB)) * 1_048_576,
            drainSeconds: max(0, config.drainSeconds),
            inFlight: inFlight,
            includeLogTail: config.alertsIncludeLogTail,
            busyTimeout: max(30, config.busyTimeoutSeconds),
            modelFitThreshold: config.modelOOMThreshold,
            modelFitWindow: config.modelOOMWindowSeconds
        )
        let coordinator = SupervisionCoordinator(engine: engine)

        var controlServer: ControlServer?
        if config.controlEnabled, let token = config.controlToken, !token.isEmpty {
            controlServer = ControlServer(
                host: ControlHostResolver.resolve(config.controlHost),
                port: config.controlPort,
                token: token,
                coordinator: coordinator,
                namedTokens: config.controlEndpointTokens,
                runnerKind: config.runnerKind.rawValue.lowercased(),
                mode: config.modeKind.rawValue,
                rebootOnWedge: config.rebootOnWedge,
                metrics: metricsProvider,
                tokenMetrics: tokenMetrics,
                onControlAction: { command, actor in
                    EventLogStore.appendAudit(command: command, actor: actor)
                }
            )
        }

        // Record a metrics sample on every pressure tick so `hearth metrics` can
        // show how memory and thermals moved over the retained window.
        let metricsHistory = MetricsHistoryStore()
        let pressureMonitor = PressureMonitor(
            metrics: metricsProvider,
            thresholds: config.pressureThresholds(),
            notify: { notification in Task.detached { await notifier.notify(notification) } },
            onSample: { sample in metricsHistory.record(sample) }
        )

        // The dead-man's-switch pulse: only while the runner is actually healthy.
        let heartbeat = HeartbeatPinger(
            urlString: config.heartbeatURL,
            intervalSeconds: config.heartbeatIntervalSeconds,
            isHealthy: { [weak engine] in await engine?.snapshot().phase == .healthy }
        )

        return SupervisorAssembly(
            engine: engine,
            coordinator: coordinator,
            controlServer: controlServer,
            metricsProvider: metricsProvider,
            processController: processController,
            runner: runner,
            notifier: notifier,
            pressureMonitor: pressureMonitor,
            heartbeat: heartbeat,
            metricsProxy: metricsProxy,
            tokenMetrics: tokenMetrics
        )
    }

    /// Build the concrete delivery channels for a config. Kept separate from the
    /// stable `ReloadableNotifier` that the engine holds so notification-only
    /// changes can apply without cycling the runner.
    static func notificationChannels(config: HearthConfig, includeLocal: Bool) -> any Notifier {
        // Vacation mode: every channel quiet, configuration untouched, events
        // still logged. The pause is one flag, not three cleared settings.
        guard !config.notificationsPaused else { return CompositeNotifier([]) }
        var notifiers: [Notifier] = []
        if includeLocal, config.localNotifications {
            notifiers.append(LocalNotifier())
        }
        if let topic = config.ntfyTopic, !topic.trimmingCharacters(in: .whitespaces).isEmpty {
            notifiers.append(NtfyNotifier(server: config.ntfyServer, topic: topic))
        }
        if let webhook = config.webhookURL, !webhook.trimmingCharacters(in: .whitespaces).isEmpty,
           let url = URL(string: webhook) {
            notifiers.append(WebhookNotifier(url: url))
        }
        return CompositeNotifier(notifiers)
    }
}
