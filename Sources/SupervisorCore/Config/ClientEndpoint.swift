// SPDX-License-Identifier: MIT

import Foundation

public extension HearthConfig {
    /// The endpoint clients must use for traffic to cross Hearth when enabled.
    var clientPort: Int { metricsProxyEnabled ? metricsProxyPort : port }
    var clientEndpoint: String { "http://\(urlAuthorityHost(for: probeHost(for: host))):\(clientPort)" }
}
