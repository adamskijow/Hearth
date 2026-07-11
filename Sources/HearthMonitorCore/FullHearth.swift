// SPDX-License-Identifier: MIT

import Foundation

/// The authenticated, read-only status endpoint of a separately installed full
/// Hearth. The bearer secret is deliberately absent; the app stores it in the
/// user's Keychain under the target ID.
public struct FullHearthEndpoint: Codable, Sendable, Equatable {
    public var scheme: String
    public var host: String
    public var port: Int

    public init(scheme: String = "http", host: String = "127.0.0.1", port: Int = 11435) {
        self.scheme = scheme.lowercased() == "https" ? "https" : "http"
        self.host = host
        self.port = port
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            issues.append("Enter the full Hearth host name or IP address.")
        } else if trimmed != host
            || trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || trimmed.contains("://")
            || trimmed.contains("/")
            || trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "?#@%")) != nil {
            issues.append("Enter only a valid host name or IP address for full Hearth.")
        }
        if scheme != "http" && scheme != "https" {
            issues.append("Full Hearth connection type must be HTTP or HTTPS.")
        }
        if !(1...65_535).contains(port) {
            issues.append("Full Hearth port must be between 1 and 65535.")
        }
        if url(path: "/status") == nil {
            issues.append("The full Hearth status address is not a valid URL.")
        }
        return issues
    }

    public var tokenTransportWarning: String? {
        guard scheme == "http", !MonitorTarget.isLoopbackHost(host) else { return nil }
        return "HTTP sends the bearer token without TLS. Use it only through an encrypted private overlay such as Tailscale, or put full Hearth behind HTTPS."
    }

    public func url(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }
}

/// Additive mirror of full Hearth's stable `/status` response. Every new field
/// is optional/defaulted so Monitor remains compatible with older full Hearth
/// versions and the server can add fields without breaking the companion.
public struct FullHearthStatus: Codable, Sendable, Equatable {
    public var phase: String
    public var runner: String
    public var mode: String?
    public var rebootOnWedge: Bool?
    public var busy: Bool
    public var models: [String]
    public var uptimeSeconds: Int?
    public var restartCount: Int
    public var consecutiveFailures: Int
    public var lastRestartReason: String?
    public var lastDownCategory: String?
    public var lastRestartCategory: String?
    public var oversizedModels: [String]
    public var deepProbeConfigured: Bool
    public var thermal: String?
    public var memoryUsedPercent: Int?
    public var runnerResidentBytes: Int64?
    public var tokensPerSecond: Double?
    public var generationTokensTotal: Int?
    public var recentEvents: [String]
    public var credentialAccess: String?

    public init(phase: String,
                runner: String,
                mode: String? = nil,
                rebootOnWedge: Bool? = nil,
                busy: Bool = false,
                models: [String] = [],
                uptimeSeconds: Int? = nil,
                restartCount: Int = 0,
                consecutiveFailures: Int = 0,
                lastRestartReason: String? = nil,
                lastDownCategory: String? = nil,
                lastRestartCategory: String? = nil,
                oversizedModels: [String] = [],
                deepProbeConfigured: Bool = false,
                thermal: String? = nil,
                memoryUsedPercent: Int? = nil,
                runnerResidentBytes: Int64? = nil,
                tokensPerSecond: Double? = nil,
                generationTokensTotal: Int? = nil,
                recentEvents: [String] = [],
                credentialAccess: String? = nil) {
        self.phase = phase
        self.runner = runner
        self.mode = mode
        self.rebootOnWedge = rebootOnWedge
        self.busy = busy
        self.models = models
        self.uptimeSeconds = uptimeSeconds
        self.restartCount = restartCount
        self.consecutiveFailures = consecutiveFailures
        self.lastRestartReason = lastRestartReason
        self.lastDownCategory = lastDownCategory
        self.lastRestartCategory = lastRestartCategory
        self.oversizedModels = oversizedModels
        self.deepProbeConfigured = deepProbeConfigured
        self.thermal = thermal
        self.memoryUsedPercent = memoryUsedPercent
        self.runnerResidentBytes = runnerResidentBytes
        self.tokensPerSecond = tokensPerSecond
        self.generationTokensTotal = generationTokensTotal
        self.recentEvents = recentEvents
        self.credentialAccess = credentialAccess
    }

    private enum CodingKeys: String, CodingKey {
        case phase, runner, mode, rebootOnWedge, busy, models, uptimeSeconds
        case restartCount, consecutiveFailures, lastRestartReason, lastDownCategory
        case lastRestartCategory, oversizedModels, deepProbeConfigured, thermal
        case memoryUsedPercent, runnerResidentBytes, tokensPerSecond
        case generationTokensTotal, recentEvents, credentialAccess
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        runner = try c.decodeIfPresent(String.self, forKey: .runner) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        rebootOnWedge = try c.decodeIfPresent(Bool.self, forKey: .rebootOnWedge)
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        uptimeSeconds = try c.decodeIfPresent(Int.self, forKey: .uptimeSeconds)
        restartCount = try c.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        lastRestartReason = try c.decodeIfPresent(String.self, forKey: .lastRestartReason)
        lastDownCategory = try c.decodeIfPresent(String.self, forKey: .lastDownCategory)
        lastRestartCategory = try c.decodeIfPresent(String.self, forKey: .lastRestartCategory)
        oversizedModels = try c.decodeIfPresent([String].self, forKey: .oversizedModels) ?? []
        deepProbeConfigured = try c.decodeIfPresent(Bool.self, forKey: .deepProbeConfigured) ?? false
        thermal = try c.decodeIfPresent(String.self, forKey: .thermal)
        memoryUsedPercent = try c.decodeIfPresent(Int.self, forKey: .memoryUsedPercent)
        runnerResidentBytes = try c.decodeIfPresent(Int64.self, forKey: .runnerResidentBytes)
        tokensPerSecond = try c.decodeIfPresent(Double.self, forKey: .tokensPerSecond)
        generationTokensTotal = try c.decodeIfPresent(Int.self, forKey: .generationTokensTotal)
        recentEvents = try c.decodeIfPresent([String].self, forKey: .recentEvents) ?? []
        credentialAccess = try c.decodeIfPresent(String.self, forKey: .credentialAccess)
    }

    public var isManaged: Bool? {
        mode.map { $0.lowercased() == "managed" }
    }
}
