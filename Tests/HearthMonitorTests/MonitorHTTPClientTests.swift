// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore
import Testing
@testable import HearthMonitor

@Suite("Monitor HTTP transport guidance")
struct MonitorHTTPClientTests {
    @Test("Common transport failures keep distinct, actionable outcomes")
    func mapsTransportErrors() {
        #expect(MonitorHTTPClient.outcome(for: URLError(.timedOut)) == .timedOut)
        #expect(MonitorHTTPClient.outcome(for: URLError(.cannotConnectToHost)) == .refused)

        guard case .failure(let localNetwork) = MonitorHTTPClient.outcome(
            for: URLError(.notConnectedToInternet)) else {
            Issue.record("expected local-network guidance")
            return
        }
        #expect(localNetwork.contains("Local Network"))
        #expect(localNetwork.contains("System Settings"))

        guard case .failure(let ats) = MonitorHTTPClient.outcome(
            for: URLError(.appTransportSecurityRequiresSecureConnection)) else {
            Issue.record("expected ATS guidance")
            return
        }
        #expect(ats.contains("HTTPS"))
        #expect(ats.contains("local/private"))
    }
}
