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
    public var runner: String            // "ollama" | "lmstudio"
    public var mode: String              // "managed" | "attached"
    public var ollamaBinaryPath: String
    public var lmStudioBinaryPath: String
    public var host: String
    public var port: Int

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

    // Notifications
    public var ntfyTopic: String?
    public var ntfyServer: String
    public var localNotifications: Bool

    // Control endpoint (phone side remote control)
    public var controlEnabled: Bool
    public var controlHost: String
    public var controlPort: Int
    public var controlToken: String?

    public init(runner: String = "ollama",
                mode: String = "managed",
                ollamaBinaryPath: String = HearthConfig.defaultOllamaBinaryPath,
                lmStudioBinaryPath: String = HearthConfig.defaultLMStudioBinaryPath,
                host: String = "127.0.0.1",
                port: Int = 11434,
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
                ntfyTopic: String? = nil,
                ntfyServer: String = "https://ntfy.sh",
                localNotifications: Bool = true,
                controlEnabled: Bool = false,
                controlHost: String = "127.0.0.1",
                controlPort: Int = 11435,
                controlToken: String? = nil) {
        self.runner = runner
        self.mode = mode
        self.ollamaBinaryPath = ollamaBinaryPath
        self.lmStudioBinaryPath = lmStudioBinaryPath
        self.host = host
        self.port = port
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
        self.ntfyTopic = ntfyTopic
        self.ntfyServer = ntfyServer
        self.localNotifications = localNotifications
        self.controlEnabled = controlEnabled
        self.controlHost = controlHost
        self.controlPort = controlPort
        self.controlToken = controlToken
    }

    /// Default Ollama binary location. Apple Silicon Homebrew installs to
    /// `/opt/homebrew/bin`; override in the config if yours lives elsewhere.
    public static let defaultOllamaBinaryPath = "/opt/homebrew/bin/ollama"

    /// Default LM Studio CLI location. `lms bootstrap` can place a symlink here;
    /// otherwise set `lmStudioBinaryPath` to wherever `lms` lives.
    public static let defaultLMStudioBinaryPath = "/usr/local/bin/lms"

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
        host = try value(.host, defaults.host)
        port = try value(.port, defaults.port)
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
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic)
        ntfyServer = try value(.ntfyServer, defaults.ntfyServer)
        localNotifications = try value(.localNotifications, defaults.localNotifications)
        controlEnabled = try value(.controlEnabled, defaults.controlEnabled)
        controlHost = try value(.controlHost, defaults.controlHost)
        controlPort = try value(.controlPort, defaults.controlPort)
        controlToken = try c.decodeIfPresent(String.self, forKey: .controlToken)
    }

    // MARK: - Derived

    /// Whether the supervisor owns and spawns the runner (managed) or only
    /// monitors an already running one (attached).
    public var isManaged: Bool {
        mode.lowercased() != "attached"
    }

    /// The restart policy these settings describe.
    public func policy() -> RestartPolicyConfig {
        RestartPolicyConfig(
            probeInterval: probeIntervalSeconds,
            probeTimeout: probeTimeoutSeconds,
            startupGrace: startupGraceSeconds,
            startupProbeInterval: startupProbeIntervalSeconds,
            initialBackoff: initialBackoffSeconds,
            backoffMultiplier: backoffMultiplier,
            maxBackoff: maxBackoffSeconds,
            crashLoopThreshold: crashLoopThreshold,
            crashLoopWindow: crashLoopWindowSeconds,
            failingProbeInterval: failingProbeIntervalSeconds
        )
    }

    /// The runner these settings select.
    public func makeRunner() -> any Runner {
        switch runner.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio":
            return LMStudioRunner(binaryPath: lmStudioBinaryPath, host: host, port: port)
        default:
            return makeOllamaRunner()
        }
    }

    /// The Ollama runner these settings describe. Kept distinct for tests and for
    /// the default path.
    public func makeOllamaRunner() -> OllamaRunner {
        OllamaRunner(binaryPath: ollamaBinaryPath, host: host, port: port)
    }

    /// The path to the binary the selected runner launches, for the menubar
    /// "binary not found" check.
    public var selectedBinaryPath: String {
        switch runner.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio":
            return lmStudioBinaryPath
        default:
            return ollamaBinaryPath
        }
    }
}
