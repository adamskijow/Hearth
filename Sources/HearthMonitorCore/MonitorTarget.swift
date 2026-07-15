// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// The non-secret authentication choice stored with a runner. The credential
/// itself lives only in Keychain in the app target.
public enum MonitorRunnerAuthentication: String, Codable, Sendable, Equatable {
    case none
    case bearer
}

/// One local or remote AI runner Hearth Monitor watches. The companion stores no
/// executable path because attached monitoring never launches code.
public struct MonitorTarget: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var isEnabled: Bool
    public var name: String
    public var runner: String
    public var scheme: String
    public var host: String
    public var port: Int
    public var probeModel: String?
    public var authentication: MonitorRunnerAuthentication
    public var fullHearth: FullHearthEndpoint?
    public var probeIntervalSeconds: TimeInterval
    public var probeTimeoutSeconds: TimeInterval
    public var deepProbeIntervalSeconds: TimeInterval
    public var deepProbeTimeoutSeconds: TimeInterval
    public var failureThreshold: Int
    public var modelRefreshIntervalSeconds: TimeInterval

    public init(id: UUID = UUID(),
                isEnabled: Bool = true,
                name: String? = nil,
                runner: String = "ollama",
                scheme: String = "http",
                host: String = "127.0.0.1",
                port: Int? = nil,
                probeModel: String? = nil,
                authentication: MonitorRunnerAuthentication = .none,
                probeIntervalSeconds: TimeInterval = 10,
                probeTimeoutSeconds: TimeInterval = 3,
                deepProbeIntervalSeconds: TimeInterval = 300,
                deepProbeTimeoutSeconds: TimeInterval = 30,
                failureThreshold: Int = 2,
                modelRefreshIntervalSeconds: TimeInterval = 30,
                fullHearth: FullHearthEndpoint? = nil) {
        let kind = RunnerKind(fromConfigString: runner)
        self.id = id
        self.isEnabled = isEnabled
        self.name = name ?? kind.displayName
        self.runner = kind.rawValue
        self.scheme = scheme.lowercased() == "https" ? "https" : "http"
        self.host = host
        self.port = port ?? kind.monitorDefaultPort
        self.probeModel = probeModel
        self.authentication = authentication
        self.fullHearth = fullHearth
        self.probeIntervalSeconds = probeIntervalSeconds
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.deepProbeIntervalSeconds = deepProbeIntervalSeconds
        self.deepProbeTimeoutSeconds = deepProbeTimeoutSeconds
        self.failureThreshold = failureThreshold
        self.modelRefreshIntervalSeconds = modelRefreshIntervalSeconds
    }

    public var runnerKind: RunnerKind { RunnerKind(fromConfigString: runner) }

    public var normalizedProbeModel: String? {
        guard let value = probeModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    public var clampedFailureThreshold: Int { max(1, failureThreshold) }
    public var clampedProbeTimeout: TimeInterval { max(0.5, probeTimeoutSeconds) }
    public var clampedDeepProbeTimeout: TimeInterval { max(1, deepProbeTimeoutSeconds) }
    public var clampedDeepProbeInterval: TimeInterval { max(5, deepProbeIntervalSeconds) }
    public var clampedModelRefreshInterval: TimeInterval { max(5, modelRefreshIntervalSeconds) }

    public var validationIssues: [String] {
        var issues: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            issues.append("Give this runner a name.")
        } else if trimmedName.count > 64 {
            issues.append("Runner name must be 64 characters or fewer.")
        } else if name.rangeOfCharacter(from: .newlines) != nil {
            issues.append("Runner name must be one line.")
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            issues.append("Enter the runner's host name or IP address.")
        } else if trimmedHost.count > 253 {
            issues.append("Host name must be 253 characters or fewer.")
        } else if trimmedHost != host
            || trimmedHost.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append("Host name cannot contain spaces.")
        } else if trimmedHost.contains("://") || trimmedHost.contains("/") {
            issues.append("Enter only a host name or IP address; choose HTTP or HTTPS separately.")
        } else if trimmedHost.rangeOfCharacter(from: CharacterSet(charactersIn: "?#@%")) != nil {
            issues.append("Host name contains a character that is not valid in an endpoint address.")
        }
        if !(1...65_535).contains(port) {
            issues.append("Port must be between 1 and 65535.")
        }
        if scheme != "http" && scheme != "https" {
            issues.append("Connection type must be HTTP or HTTPS.")
        }
        if !RunnerKind.knownConfigStrings.contains(runner.lowercased()) {
            issues.append("Choose a supported runner type.")
        }
        if !probeIntervalSeconds.isFinite || probeIntervalSeconds < 2 {
            issues.append("Check interval must be at least 2 seconds.")
        }
        if !probeTimeoutSeconds.isFinite || probeTimeoutSeconds <= 0 {
            issues.append("Check timeout must be greater than zero.")
        }
        if !deepProbeIntervalSeconds.isFinite || deepProbeIntervalSeconds < 5 {
            issues.append("Inference check interval must be at least 5 seconds.")
        }
        if !deepProbeTimeoutSeconds.isFinite || deepProbeTimeoutSeconds <= 0 {
            issues.append("Inference check timeout must be greater than zero.")
        }
        if failureThreshold < 1 {
            issues.append("Failure confirmation must require at least one check.")
        }
        if !modelRefreshIntervalSeconds.isFinite || modelRefreshIntervalSeconds < 5 {
            issues.append("Model refresh interval must be at least 5 seconds.")
        }
        if let model = normalizedProbeModel, model.count > 256 {
            issues.append("Probe model name must be 256 characters or fewer.")
        }
        if let fullHearth {
            issues.append(contentsOf: fullHearth.validationIssues)
        }
        return issues
    }

    /// HTTP is appropriate for a runner on the same Mac or a trusted private
    /// network, but it should not be presented as a safe remote transport. This
    /// is advisory rather than a validation failure because local DNS names do
    /// not have one reliable suffix and an administrator may intentionally use
    /// one on a private network.
    public var transportAdvisory: String? {
        guard scheme == "http", !Self.isClearlyLocalHost(host) else { return nil }
        return "HTTP is unencrypted. Use HTTPS unless this runner is on a trusted private network."
    }

    public static func isClearlyLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            return octets[0] == 127
                || octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 100 && (64...127).contains(octets[1]))
        }
        return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
    }

    public static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4
            && octets.allSatisfy { (0...255).contains($0) }
            && octets[0] == 127
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, name, runner, scheme, host, port, probeModel, authentication, fullHearth
        case probeIntervalSeconds, probeTimeoutSeconds
        case deepProbeIntervalSeconds, deepProbeTimeoutSeconds
        case failureThreshold, modelRefreshIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let defaults = MonitorTarget()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        runner = try container.decodeIfPresent(String.self, forKey: .runner) ?? defaults.runner
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? defaults.scheme
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        probeModel = try container.decodeIfPresent(String.self, forKey: .probeModel)
        authentication = try container.decodeIfPresent(
            MonitorRunnerAuthentication.self, forKey: .authentication) ?? defaults.authentication
        fullHearth = try container.decodeIfPresent(FullHearthEndpoint.self, forKey: .fullHearth)
        probeIntervalSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .probeIntervalSeconds) ?? defaults.probeIntervalSeconds
        probeTimeoutSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .probeTimeoutSeconds) ?? defaults.probeTimeoutSeconds
        deepProbeIntervalSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .deepProbeIntervalSeconds) ?? defaults.deepProbeIntervalSeconds
        deepProbeTimeoutSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .deepProbeTimeoutSeconds) ?? defaults.deepProbeTimeoutSeconds
        failureThreshold = try container.decodeIfPresent(
            Int.self, forKey: .failureThreshold) ?? defaults.failureThreshold
        modelRefreshIntervalSeconds = try container.decodeIfPresent(
            TimeInterval.self, forKey: .modelRefreshIntervalSeconds) ?? defaults.modelRefreshIntervalSeconds
    }
}

public extension RunnerKind {
    var monitorDefaultPort: Int {
        switch self {
        case .ollama: return 11434
        case .lmStudio: return 1234
        case .mlx: return 8080
        case .osaurus: return 1337
        }
    }
}

/// The runner HTTP surface, narrowed so the monitor engine cannot even ask for a
/// process specification. Existing SupervisorCore runners remain the source of
/// truth for endpoint paths and response parsing.
struct MonitorRunnerAPI: Sendable {
    private let base: any Runner
    private let scheme: String

    init(target: MonitorTarget) {
        scheme = target.scheme
        let placeholder = "/dev/null"
        switch target.runnerKind {
        case .ollama:
            base = OllamaRunner(binaryPath: placeholder, host: target.host, port: target.port)
        case .lmStudio:
            base = LMStudioRunner(binaryPath: placeholder, host: target.host, port: target.port)
        case .mlx:
            base = MLXRunner(binaryPath: placeholder, host: target.host, port: target.port)
        case .osaurus:
            base = OsaurusRunner(binaryPath: placeholder, host: target.host, port: target.port)
        }
    }

    var name: String { base.name }
    var readinessEndpoint: URL { withScheme(base.readinessEndpoint) }
    var modelsEndpoint: URL { withScheme(base.modelsEndpoint) }
    var availableModelsEndpoint: URL { withScheme(base.availableModelsEndpoint) }
    func parseResidentModels(_ data: Data) throws -> [ResidentModel] {
        try base.parseResidentModels(data)
    }
    func parseAvailableModels(_ data: Data) throws -> [AvailableModel] {
        try base.parseAvailableModels(data)
    }
    func isCompatibleDiscoveryResponse(_ data: Data) -> Bool {
        switch base.name {
        case "Ollama":
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["version"] is String
        default:
            return (try? base.parseAvailableModels(data)) != nil
        }
    }
    func deepReadinessRequest(model: String, unloadAfter: Bool = false) -> DeepProbeRequest? {
        guard let request = base.deepReadinessRequest(
            model: model, unloadAfter: unloadAfter) else { return nil }
        return DeepProbeRequest(url: withScheme(request.url), body: request.body)
    }

    private func withScheme(_ url: URL) -> URL {
        guard scheme == "https", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }
}
