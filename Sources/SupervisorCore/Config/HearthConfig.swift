// SPDX-License-Identifier: MIT

import Foundation

/// The whole configurable surface, loaded from a JSON file at a standard path.
/// Data driven on purpose: every timing knob, the runner location, and the
/// notification settings live here rather than as constants in code. Decoding is
/// lenient, every key is optional, and missing keys fall back to the documented
/// defaults, so a partial or empty config file still works.
public struct HearthConfig: Codable, Sendable, Equatable {
    // Runner
    public var ollamaBinaryPath: String
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

    public init(ollamaBinaryPath: String = HearthConfig.defaultBinaryPath,
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
                localNotifications: Bool = true) {
        self.ollamaBinaryPath = ollamaBinaryPath
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
    }

    /// The default Ollama binary location. Apple Silicon Homebrew installs to
    /// `/opt/homebrew/bin`; override in the config if yours lives elsewhere.
    public static let defaultBinaryPath = "/opt/homebrew/bin/ollama"

    // Lenient decoding: every key optional, fall back to defaults.
    public init(from decoder: Decoder) throws {
        let defaults = HearthConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        ollamaBinaryPath = try value(.ollamaBinaryPath, defaults.ollamaBinaryPath)
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
    }

    // MARK: - Derived

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

    /// The Ollama runner these settings describe.
    public func makeOllamaRunner() -> OllamaRunner {
        OllamaRunner(binaryPath: ollamaBinaryPath, host: host, port: port)
    }
}
