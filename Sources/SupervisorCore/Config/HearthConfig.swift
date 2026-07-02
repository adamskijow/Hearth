// SPDX-License-Identifier: MIT

import Foundation

/// The whole configurable surface, loaded from a JSON file at a standard path.
/// Data driven on purpose: every timing knob, the runner choice and location,
/// the supervision mode, the notification settings, and the optional control
/// endpoint all live here rather than as constants in code. Decoding is lenient,
/// every key is optional, and missing keys fall back to the documented defaults,
/// so a partial or empty config file still works.
public struct HearthConfig: Codable, Sendable, Equatable {
    // Runner selection
    public var runner: String            // "ollama" | "lmstudio" | "mlx"
    public var mode: String              // "managed" | "attached"
    public var ollamaBinaryPath: String
    public var lmStudioBinaryPath: String
    public var mlxBinaryPath: String
    public var osaurusBinaryPath: String
    public var host: String
    public var port: Int
    /// Extra environment variables to set on a managed runner process, so a
    /// hand-tuned setup (OLLAMA_LOAD_TIMEOUT, OLLAMA_KEEP_ALIVE, OLLAMA_NUM_PARALLEL
    /// and the like) is a config key, not a launchd plist edit. Merged into the
    /// child's environment at spawn. Hearth still derives the bind address itself,
    /// so a value for OLLAMA_HOST here is ignored in favor of host and port.
    public var runnerEnv: [String: String]

    // Health and restart policy
    public var probeTimeoutSeconds: Double
    public var probeIntervalSeconds: Double
    public var startupGraceSeconds: Double
    public var startupProbeIntervalSeconds: Double
    public var initialBackoffSeconds: Double
    public var backoffMultiplier: Double
    public var maxBackoffSeconds: Double
    public var crashLoopThreshold: Int
    public var crashLoopWindowSeconds: Double
    public var failingProbeIntervalSeconds: Double
    /// Cycle a long-healthy runner this often (in hours) to clear memory creep.
    /// Zero disables it; a common value for a 24/7 server is 24.
    public var maintenanceRestartHours: Double
    /// Optional daily window ("HH:MM-HH:MM", 24-hour local time) during which
    /// scheduled maintenance restarts may fire; a due restart waits for it.
    /// Spans midnight when the end is before the start. Nil means any time.
    public var maintenanceWindow: String?
    /// After a restart, load the models that were resident before it (a
    /// one-token generation each), so recovery does not hand the next request a
    /// multi-gigabyte cold start. Off by default: it does GPU work unprompted.
    public var warmModelsAfterRestart: Bool
    /// Restart a healthy managed runner whose resident memory crosses this many
    /// megabytes, catching the RSS-creep slow death before it becomes a wedge.
    /// Zero disables the watchdog.
    public var runnerMemoryLimitMB: Int
    /// Restart the runner when its binary changes on disk (an upgrade), so a
    /// managed runner adopts the new version instead of serving the old one. Off
    /// by default.
    public var restartOnBinaryChange: Bool
    /// Optional deep readiness probe. When `probeModel` is set, Hearth periodically
    /// runs a one-token generation against that model, on top of the cheap shallow
    /// probe, to catch a wedged model runner that still answers the shallow
    /// endpoint. Off by default (no probe model).
    public var probeModel: String?
    public var deepProbeIntervalSeconds: Double
    public var deepProbeTimeoutSeconds: Double

    // Notifications
    public var ntfyTopic: String?
    public var ntfyServer: String
    /// POST a small JSON status body to this URL on each notification, to wire
    /// Hearth into your own automation. Null disables it.
    public var webhookURL: String?
    public var localNotifications: Bool
    /// Alert when system memory used reaches this percent (a precursor to the
    /// runner being killed under pressure). Zero disables the memory alert.
    public var memoryAlertPercent: Int
    /// Alert when the Mac's thermal state is serious or critical.
    public var thermalAlerts: Bool
    /// Silence every notification channel (local, ntfy, webhook) without
    /// touching their configuration: vacation mode. Events are still logged.
    public var notificationsPaused: Bool
    /// Optional dead-man's-switch heartbeat: while the runner is healthy, GET
    /// this URL on an interval (an Uptime Kuma push monitor or a
    /// healthchecks.io check). Silence then means down, and the monitor you
    /// already run does the alerting. Nil disables it.
    public var heartbeatURL: String?
    public var heartbeatIntervalSeconds: Double

    // Control endpoint (phone side remote control)
    public var controlEnabled: Bool
    public var controlHost: String
    public var controlPort: Int
    public var controlToken: String?

    // Opt-in tokens-per-second tap: a transparent relay in front of the runner.
    // Clients point at metricsProxyPort instead of the runner port; bytes pass
    // through untouched while the response side is scanned for the throughput
    // numbers the runner itself reports, surfaced in /metrics.
    public var metricsProxyEnabled: Bool
    public var metricsProxyPort: Int
    /// How long a routine restart (scheduled maintenance, a binary upgrade) may
    /// wait for in-flight generations to finish before proceeding anyway.
    /// Needs the metrics proxy (the only place in-flight work is observable);
    /// zero restarts immediately. Failure restarts never wait.
    public var drainSeconds: Double

    // Runner log rotation
    public var logMaxBytes: Int
    public var logKeepFiles: Int

    // Reboot escalation: recover a driver/GPU-level wedge a process restart cannot.
    // Off by default; needs Hearth running as root (the headless LaunchDaemon).
    public var rebootOnWedge: Bool
    public var rebootEscalateAfterSeconds: Double
    public var rebootMinIntervalSeconds: Double
    public var rebootMaxPerDay: Int
    /// When true, a reboot fires only if the failing streak included an actual
    /// process exit (a crash the runner cannot fake over HTTP), never for a pure
    /// "alive but not answering" wedge. Off by default: the wedge is exactly what
    /// reboot-on-wedge targets, so turning this on trades unattended recovery of a
    /// pure wedge for not letting a runner that only controls its HTTP responses
    /// drive the machine into a reboot. For operators who do not fully trust the
    /// runner. A pure wedge then escalates to a notification instead.
    public var rebootOnlyOnProcessFailure: Bool
    /// EXPERIMENTAL: send the recovery reboot through the hearth-reboot-helper
    /// root daemon instead of rebooting directly, so the supervisor itself need
    /// not run as root. Needs the helper installed (see docs/running-headless.md).
    public var rebootViaHelper: Bool
    /// The helper's unix socket path.
    public var rebootHelperSocket: String

    /// The account to drop the spawned runner to when Hearth runs as the root
    /// daemon. The parent stays root (so it keeps the reboot capability), while the
    /// runner it spawns, which loads untrusted models and answers the network, runs
    /// as this lower-privileged account. Required for managed root-daemon mode:
    /// nil, an unresolved account, or root itself fails closed rather than running
    /// the runner as root. Ignored for the non-root menubar app. See
    /// docs/configuration.md, and test that GPU inference still works under the
    /// account before relying on it.
    public var runnerUser: String?

    public init(runner: String = "ollama",
                mode: String = "managed",
                ollamaBinaryPath: String = HearthConfig.defaultOllamaBinaryPath,
                lmStudioBinaryPath: String = HearthConfig.defaultLMStudioBinaryPath,
                mlxBinaryPath: String = HearthConfig.defaultMLXBinaryPath,
                osaurusBinaryPath: String = HearthConfig.defaultOsaurusBinaryPath,
                host: String = "127.0.0.1",
                port: Int = 11434,
                runnerEnv: [String: String] = [:],
                probeTimeoutSeconds: Double = 2,
                probeIntervalSeconds: Double = 5,
                startupGraceSeconds: Double = 30,
                startupProbeIntervalSeconds: Double = 1,
                initialBackoffSeconds: Double = 1,
                backoffMultiplier: Double = 2,
                maxBackoffSeconds: Double = 60,
                crashLoopThreshold: Int = 5,
                crashLoopWindowSeconds: Double = 60,
                failingProbeIntervalSeconds: Double = 30,
                maintenanceRestartHours: Double = 0,
                maintenanceWindow: String? = nil,
                warmModelsAfterRestart: Bool = false,
                runnerMemoryLimitMB: Int = 0,
                restartOnBinaryChange: Bool = false,
                probeModel: String? = nil,
                deepProbeIntervalSeconds: Double = 60,
                deepProbeTimeoutSeconds: Double = 30,
                ntfyTopic: String? = nil,
                ntfyServer: String = "https://ntfy.sh",
                webhookURL: String? = nil,
                localNotifications: Bool = true,
                memoryAlertPercent: Int = 90,
                thermalAlerts: Bool = true,
                notificationsPaused: Bool = false,
                heartbeatURL: String? = nil,
                heartbeatIntervalSeconds: Double = 60,
                controlEnabled: Bool = false,
                controlHost: String = "127.0.0.1",
                controlPort: Int = 11435,
                controlToken: String? = nil,
                metricsProxyEnabled: Bool = false,
                metricsProxyPort: Int = 11436,
                drainSeconds: Double = 0,
                logMaxBytes: Int = 5_000_000,
                logKeepFiles: Int = 3,
                rebootOnWedge: Bool = false,
                rebootEscalateAfterSeconds: Double = 600,
                rebootMinIntervalSeconds: Double = 1800,
                rebootMaxPerDay: Int = 3,
                rebootOnlyOnProcessFailure: Bool = false,
                rebootViaHelper: Bool = false,
                rebootHelperSocket: String = "/var/run/hearth-reboot.sock",
                runnerUser: String? = nil) {
        self.runner = runner
        self.mode = mode
        self.ollamaBinaryPath = ollamaBinaryPath
        self.lmStudioBinaryPath = lmStudioBinaryPath
        self.mlxBinaryPath = mlxBinaryPath
        self.osaurusBinaryPath = osaurusBinaryPath
        self.host = host
        self.port = port
        self.runnerEnv = runnerEnv
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.probeIntervalSeconds = probeIntervalSeconds
        self.startupGraceSeconds = startupGraceSeconds
        self.startupProbeIntervalSeconds = startupProbeIntervalSeconds
        self.initialBackoffSeconds = initialBackoffSeconds
        self.backoffMultiplier = backoffMultiplier
        self.maxBackoffSeconds = maxBackoffSeconds
        self.crashLoopThreshold = crashLoopThreshold
        self.crashLoopWindowSeconds = crashLoopWindowSeconds
        self.failingProbeIntervalSeconds = failingProbeIntervalSeconds
        self.maintenanceRestartHours = maintenanceRestartHours
        self.maintenanceWindow = maintenanceWindow
        self.warmModelsAfterRestart = warmModelsAfterRestart
        self.runnerMemoryLimitMB = runnerMemoryLimitMB
        self.restartOnBinaryChange = restartOnBinaryChange
        self.probeModel = probeModel
        self.deepProbeIntervalSeconds = deepProbeIntervalSeconds
        self.deepProbeTimeoutSeconds = deepProbeTimeoutSeconds
        self.ntfyTopic = ntfyTopic
        self.ntfyServer = ntfyServer
        self.webhookURL = webhookURL
        self.localNotifications = localNotifications
        self.memoryAlertPercent = memoryAlertPercent
        self.thermalAlerts = thermalAlerts
        self.notificationsPaused = notificationsPaused
        self.heartbeatURL = heartbeatURL
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.controlEnabled = controlEnabled
        self.controlHost = controlHost
        self.controlPort = controlPort
        self.controlToken = controlToken
        self.metricsProxyEnabled = metricsProxyEnabled
        self.metricsProxyPort = metricsProxyPort
        self.drainSeconds = drainSeconds
        self.logMaxBytes = logMaxBytes
        self.logKeepFiles = logKeepFiles
        self.rebootOnWedge = rebootOnWedge
        self.rebootEscalateAfterSeconds = rebootEscalateAfterSeconds
        self.rebootMinIntervalSeconds = rebootMinIntervalSeconds
        self.rebootMaxPerDay = rebootMaxPerDay
        self.rebootOnlyOnProcessFailure = rebootOnlyOnProcessFailure
        self.rebootViaHelper = rebootViaHelper
        self.rebootHelperSocket = rebootHelperSocket
        self.runnerUser = runnerUser
    }

    /// Default Ollama binary location. Apple Silicon Homebrew installs to
    /// `/opt/homebrew/bin`; override in the config if yours lives elsewhere.
    public static let defaultOllamaBinaryPath = "/opt/homebrew/bin/ollama"

    /// Default LM Studio CLI location. `lms bootstrap` can place a symlink here;
    /// otherwise set `lmStudioBinaryPath` to wherever `lms` lives.
    public static let defaultLMStudioBinaryPath = "/usr/local/bin/lms"

    /// Default mlx_lm server location. pip puts the console script in the active
    /// environment's bin; set `mlxBinaryPath` to wherever `mlx_lm.server` lives.
    public static let defaultMLXBinaryPath = "/opt/homebrew/bin/mlx_lm.server"

    /// Default Osaurus CLI location: the app bundle binary, which exists whenever
    /// the app is installed. Homebrew also links it as `osaurus` on the PATH.
    public static let defaultOsaurusBinaryPath = "/Applications/Osaurus.app/Contents/MacOS/osaurus"

    // Lenient decoding: every key optional, fall back to defaults.
    public init(from decoder: Decoder) throws {
        let defaults = HearthConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        runner = try value(.runner, defaults.runner)
        mode = try value(.mode, defaults.mode)
        ollamaBinaryPath = try value(.ollamaBinaryPath, defaults.ollamaBinaryPath)
        lmStudioBinaryPath = try value(.lmStudioBinaryPath, defaults.lmStudioBinaryPath)
        mlxBinaryPath = try value(.mlxBinaryPath, defaults.mlxBinaryPath)
        osaurusBinaryPath = try value(.osaurusBinaryPath, defaults.osaurusBinaryPath)
        host = try value(.host, defaults.host)
        port = try value(.port, defaults.port)
        runnerEnv = try value(.runnerEnv, defaults.runnerEnv)
        probeTimeoutSeconds = try value(.probeTimeoutSeconds, defaults.probeTimeoutSeconds)
        probeIntervalSeconds = try value(.probeIntervalSeconds, defaults.probeIntervalSeconds)
        startupGraceSeconds = try value(.startupGraceSeconds, defaults.startupGraceSeconds)
        startupProbeIntervalSeconds = try value(.startupProbeIntervalSeconds, defaults.startupProbeIntervalSeconds)
        initialBackoffSeconds = try value(.initialBackoffSeconds, defaults.initialBackoffSeconds)
        backoffMultiplier = try value(.backoffMultiplier, defaults.backoffMultiplier)
        maxBackoffSeconds = try value(.maxBackoffSeconds, defaults.maxBackoffSeconds)
        crashLoopThreshold = try value(.crashLoopThreshold, defaults.crashLoopThreshold)
        crashLoopWindowSeconds = try value(.crashLoopWindowSeconds, defaults.crashLoopWindowSeconds)
        failingProbeIntervalSeconds = try value(.failingProbeIntervalSeconds, defaults.failingProbeIntervalSeconds)
        maintenanceRestartHours = try value(.maintenanceRestartHours, defaults.maintenanceRestartHours)
        maintenanceWindow = try c.decodeIfPresent(String.self, forKey: .maintenanceWindow)
        warmModelsAfterRestart = try value(.warmModelsAfterRestart, defaults.warmModelsAfterRestart)
        runnerMemoryLimitMB = try value(.runnerMemoryLimitMB, defaults.runnerMemoryLimitMB)
        restartOnBinaryChange = try value(.restartOnBinaryChange, defaults.restartOnBinaryChange)
        probeModel = try c.decodeIfPresent(String.self, forKey: .probeModel)
        deepProbeIntervalSeconds = try value(.deepProbeIntervalSeconds, defaults.deepProbeIntervalSeconds)
        deepProbeTimeoutSeconds = try value(.deepProbeTimeoutSeconds, defaults.deepProbeTimeoutSeconds)
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic)
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL)
        ntfyServer = try value(.ntfyServer, defaults.ntfyServer)
        localNotifications = try value(.localNotifications, defaults.localNotifications)
        memoryAlertPercent = try value(.memoryAlertPercent, defaults.memoryAlertPercent)
        thermalAlerts = try value(.thermalAlerts, defaults.thermalAlerts)
        notificationsPaused = try value(.notificationsPaused, defaults.notificationsPaused)
        heartbeatURL = try c.decodeIfPresent(String.self, forKey: .heartbeatURL)
        heartbeatIntervalSeconds = try value(.heartbeatIntervalSeconds, defaults.heartbeatIntervalSeconds)
        controlEnabled = try value(.controlEnabled, defaults.controlEnabled)
        controlHost = try value(.controlHost, defaults.controlHost)
        controlPort = try value(.controlPort, defaults.controlPort)
        controlToken = try c.decodeIfPresent(String.self, forKey: .controlToken)
        metricsProxyEnabled = try value(.metricsProxyEnabled, defaults.metricsProxyEnabled)
        metricsProxyPort = try value(.metricsProxyPort, defaults.metricsProxyPort)
        drainSeconds = try value(.drainSeconds, defaults.drainSeconds)
        logMaxBytes = try value(.logMaxBytes, defaults.logMaxBytes)
        logKeepFiles = try value(.logKeepFiles, defaults.logKeepFiles)
        rebootOnWedge = try value(.rebootOnWedge, defaults.rebootOnWedge)
        rebootEscalateAfterSeconds = try value(.rebootEscalateAfterSeconds, defaults.rebootEscalateAfterSeconds)
        rebootMinIntervalSeconds = try value(.rebootMinIntervalSeconds, defaults.rebootMinIntervalSeconds)
        rebootMaxPerDay = try value(.rebootMaxPerDay, defaults.rebootMaxPerDay)
        rebootOnlyOnProcessFailure = try value(.rebootOnlyOnProcessFailure, defaults.rebootOnlyOnProcessFailure)
        rebootViaHelper = try value(.rebootViaHelper, defaults.rebootViaHelper)
        rebootHelperSocket = try value(.rebootHelperSocket, defaults.rebootHelperSocket)
        runnerUser = try c.decodeIfPresent(String.self, forKey: .runnerUser)
    }

    // MARK: - Derived

    /// Whether the supervisor owns and spawns the runner (managed) or only
    /// monitors an already running one (attached).
    public var isManaged: Bool {
        mode.lowercased() != "attached"
    }

    /// The configured runner account after shell-style whitespace is removed.
    /// Empty strings are treated the same as an unset `runnerUser`.
    public var normalizedRunnerUser: String? {
        guard let trimmed = runnerUser?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The restart policy these settings describe. Values that would brick
    /// supervision are clamped to a safe floor here, independent of the
    /// `ConfigDiagnostics` warnings: a non-positive probe interval would busy
    /// spin, a multiplier below 1 would shrink backoff toward zero, and a crash
    /// loop threshold below 1 would trip the brake on the first failure.
    public func policy() -> RestartPolicyConfig {
        RestartPolicyConfig(
            probeInterval: max(0.1, probeIntervalSeconds),
            probeTimeout: probeTimeoutSeconds,
            startupGrace: startupGraceSeconds,
            startupProbeInterval: max(0.1, startupProbeIntervalSeconds),
            // A non-positive initial backoff would respawn a failing runner in a
            // tight, no-delay loop until the crash-loop brake; a max below the
            // initial would keep backoff from ever growing.
            initialBackoff: max(0.1, initialBackoffSeconds),
            backoffMultiplier: max(1, backoffMultiplier),
            maxBackoff: max(max(0.1, initialBackoffSeconds), maxBackoffSeconds),
            crashLoopThreshold: max(1, crashLoopThreshold),
            crashLoopWindow: crashLoopWindowSeconds,
            failingProbeInterval: max(0.1, failingProbeIntervalSeconds),
            // Enabled values are floored at one hour so a tiny setting cannot make
            // Hearth restart the runner in a tight loop.
            maintenanceRestartInterval: maintenanceRestartHours <= 0 ? 0 : max(3600, maintenanceRestartHours * 3600),
            restartOnBinaryChange: restartOnBinaryChange,
            maintenanceWindow: maintenanceWindow.flatMap(MaintenanceWindow.parse)
        )
    }

    /// The deep readiness probe these settings describe, or nil when disabled (no
    /// probe model). Floors keep a misconfiguration from busy-probing.
    public func deepProbe() -> DeepProbeConfig? {
        guard let model = probeModel?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return DeepProbeConfig(
            model: model,
            interval: max(5, deepProbeIntervalSeconds),
            timeout: max(1, deepProbeTimeoutSeconds))
    }

    /// The memory and thermal pressure alert thresholds these settings describe.
    public func pressureThresholds() -> PressureThresholds {
        PressureThresholds(memoryAlertPercent: memoryAlertPercent, thermalAlerts: thermalAlerts)
    }

    /// The runner log rotation policy these settings describe.
    public func logRotationPolicy() -> LogRotationPolicy {
        LogRotationPolicy(maxBytes: logMaxBytes, keepFiles: logKeepFiles)
    }

    /// The reboot escalation policy these settings describe. Clamped to safe
    /// floors so a misconfiguration cannot make Hearth reboot-happy.
    public func rebootPolicy() -> RebootPolicy {
        RebootPolicy(
            enabled: rebootOnWedge,
            escalateAfterSeconds: max(60, rebootEscalateAfterSeconds),
            minIntervalSeconds: max(300, rebootMinIntervalSeconds),
            maxPerDay: max(1, rebootMaxPerDay),
            requireProcessFailure: rebootOnlyOnProcessFailure
        )
    }

    /// The runner kind these settings select, resolving the `runner` aliases once.
    public var runnerKind: RunnerKind { RunnerKind(fromConfigString: runner) }

    /// The supervision mode these settings select, resolving the `mode` string once.
    public var modeKind: ModeKind { ModeKind(fromConfigString: mode) }

    /// The runner these settings select.
    public func makeRunner() -> any Runner {
        switch runnerKind {
        case .lmStudio:
            return LMStudioRunner(binaryPath: lmStudioBinaryPath, host: host, port: port, extraEnvironment: runnerEnv)
        case .mlx:
            return MLXRunner(binaryPath: mlxBinaryPath, host: host, port: port, extraEnvironment: runnerEnv)
        case .osaurus:
            return OsaurusRunner(binaryPath: osaurusBinaryPath, host: host, port: port, extraEnvironment: runnerEnv)
        case .ollama:
            return makeOllamaRunner()
        }
    }

    /// The Ollama runner these settings describe. Kept distinct for tests and for
    /// the default path.
    public func makeOllamaRunner() -> OllamaRunner {
        OllamaRunner(binaryPath: ollamaBinaryPath, host: host, port: port, extraEnvironment: runnerEnv)
    }

    /// The path to the binary the selected runner launches, for the menubar
    /// "binary not found" check.
    public var selectedBinaryPath: String {
        switch runnerKind {
        case .lmStudio: return lmStudioBinaryPath
        case .mlx: return mlxBinaryPath
        case .osaurus: return osaurusBinaryPath
        case .ollama: return ollamaBinaryPath
        }
    }

    /// Set the binary path for the currently selected runner. One place so the
    /// first-run template and `hearth setup` cannot drift on which field to write.
    public mutating func setSelectedBinaryPath(_ path: String) {
        switch runnerKind {
        case .lmStudio: lmStudioBinaryPath = path
        case .mlx: mlxBinaryPath = path
        case .osaurus: osaurusBinaryPath = path
        case .ollama: ollamaBinaryPath = path
        }
    }
}
