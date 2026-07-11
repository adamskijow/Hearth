// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

public struct DiscoveredRunner: Identifiable, Sendable, Equatable {
    public var kind: RunnerKind
    public var host: String
    public var port: Int
    public var id: String { "\(kind.rawValue)@\(host):\(port)" }

    public init(kind: RunnerKind, host: String, port: Int) {
        self.kind = kind
        self.host = host
        self.port = port
    }
}

public enum MonitorDiscovery {
    /// Probe the conventional endpoint for every supported runner concurrently.
    /// Only a 2xx or 503 is a match; a listener for some unrelated service must
    /// not be presented as a discovered AI runner.
    public static func discover(host: String = "127.0.0.1",
                                http: any HTTPClient,
                                timeout: TimeInterval = 1.5) async -> [DiscoveredRunner] {
        await withTaskGroup(of: DiscoveredRunner?.self) { group in
            for kind in RunnerKind.allCases {
                group.addTask {
                    let target = MonitorTarget(runner: kind.rawValue, host: host)
                    let api = MonitorRunnerAPI(target: target)
                    let outcome = await http.get(api.readinessEndpoint, timeout: max(0.5, timeout))
                    switch outcome {
                    case .ok(let data) where api.isCompatibleDiscoveryResponse(data):
                        return DiscoveredRunner(kind: kind, host: host, port: target.port)
                    case .http(status: 503, body: _):
                        return DiscoveredRunner(kind: kind, host: host, port: target.port)
                    default:
                        return nil
                    }
                }
            }
            var found: [DiscoveredRunner] = []
            for await result in group {
                if let result { found.append(result) }
            }
            return found.sorted { left, right in
                RunnerKind.allCases.firstIndex(of: left.kind)!
                    < RunnerKind.allCases.firstIndex(of: right.kind)!
            }
        }
    }
}
