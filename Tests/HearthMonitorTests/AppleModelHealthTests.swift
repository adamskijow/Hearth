// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import Testing
@testable import HearthMonitor

@Suite("Apple model health")
struct AppleModelHealthTests {
    actor Probe: AppleModelProbing {
        var availabilityValue: AppleModelAvailability
        var results: [AppleModelFunctionalResult]
        var functionalCalls = 0

        init(availability: AppleModelAvailability = .available,
             results: [AppleModelFunctionalResult] = [.completed(1)]) {
            availabilityValue = availability
            self.results = results
        }

        func availability() -> AppleModelAvailability { availabilityValue }

        func runFunctionalCheck(timeout: TimeInterval) -> AppleModelFunctionalResult {
            functionalCalls += 1
            return results.isEmpty ? .completed(1) : results.removeFirst()
        }

        func callCount() -> Int { functionalCalls }
        func setAvailability(_ value: AppleModelAvailability) { availabilityValue = value }
    }

    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("Passive availability does not spend inference")
    func passiveOnly() async {
        let probe = Probe()
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: false),
            probe: probe,
            now: start)

        let snapshot = await engine.check(now: start)
        #expect(snapshot.phase == .available)
        #expect(await probe.callCount() == 0)
    }

    @Test("Functional success establishes health and respects cadence")
    func healthyCadence() async {
        let probe = Probe(results: [.completed(1.25), .completed(1.5)])
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: probe,
            now: start)

        var snapshot = await engine.check(now: start)
        #expect(snapshot.phase == .healthy)
        #expect(snapshot.lastLatencySeconds == 1.25)
        #expect(snapshot.functionalSucceededAt == start)
        snapshot = await engine.check(now: start.addingTimeInterval(60))
        #expect(snapshot.lastLatencySeconds == 1.25)
        #expect(await probe.callCount() == 1)
        snapshot = await engine.check(now: start.addingTimeInterval(901))
        #expect(snapshot.lastLatencySeconds == 1.5)
        #expect(await probe.callCount() == 2)
    }

    @Test("Timeout requires confirmation and real generation closes it")
    func confirmedTimeoutAndRecovery() async {
        let probe = Probe(results: [.timedOut, .timedOut, .completed(2)])
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: probe,
            now: start)

        var snapshot = await engine.check(now: start, forceFunctional: true)
        #expect(snapshot.phase == .verifying)
        #expect(snapshot.consecutiveFailures == 1)
        snapshot = await engine.check(now: start.addingTimeInterval(31), forceFunctional: true)
        #expect(snapshot.phase == .down)
        #expect(snapshot.hasConfirmedIncident)
        snapshot = await engine.check(now: start.addingTimeInterval(62), forceFunctional: true)
        #expect(snapshot.phase == .healthy)
        #expect(snapshot.failure == nil)
    }

    @Test("A stuck prior request is not treated as recovery")
    func noFalseRecovery() async {
        let probe = Probe(results: [.timedOut, .requestStillRunning])
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: probe,
            now: start)

        var snapshot = await engine.check(now: start, forceFunctional: true)
        #expect(snapshot.phase == .verifying)
        snapshot = await engine.check(now: start.addingTimeInterval(31), forceFunctional: true)
        #expect(snapshot.phase == .verifying)
        #expect(snapshot.failure == .timedOut)
        #expect(snapshot.functionalCheckedAt == start)
        #expect(snapshot.functionalSucceededAt == nil)
        #expect(snapshot.deferredReason?.contains("will not stack") == true)
    }

    @Test("Rate limiting and energy deferral are not outages")
    func neutralDeferrals() async {
        let probe = Probe(results: [.rateLimited])
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: probe,
            now: start)

        var snapshot = await engine.check(now: start, functionalChecksAllowed: false)
        #expect(snapshot.phase == .checking)
        #expect(snapshot.failure == nil)
        #expect(await probe.callCount() == 0)
        snapshot = await engine.check(now: start, forceFunctional: true)
        #expect(snapshot.failure == nil)
        #expect(snapshot.deferredReason?.contains("wait") == true)
    }

    @Test("Unavailable reasons remain distinct and do not create a wedge")
    func unavailable() async {
        let probe = Probe(availability: .unavailable(.appleIntelligenceNotEnabled))
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: probe,
            now: start)

        let snapshot = await engine.check(now: start)
        #expect(snapshot.phase == .unavailable)
        #expect(snapshot.availability == .unavailable(.appleIntelligenceNotEnabled))
        #expect(snapshot.failure == nil)
        #expect(await probe.callCount() == 0)
    }

    @Test("Assets and locale outcomes are availability states, not incidents")
    func functionalAvailabilityOutcomes() async {
        let assets = Probe(results: [.modelNotReady])
        let assetsEngine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: assets,
            now: start)
        var snapshot = await assetsEngine.check(now: start, forceFunctional: true)
        #expect(snapshot.phase == .unavailable)
        #expect(snapshot.availability == .unavailable(.modelNotReady))
        #expect(snapshot.failure == nil)

        let locale = Probe(results: [.unsupportedLocale])
        let localeEngine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: locale,
            now: start)
        snapshot = await localeEngine.check(now: start, forceFunctional: true)
        #expect(snapshot.phase == .unavailable)
        #expect(snapshot.availability == .unavailable(.unsupportedLocale))
        #expect(snapshot.failure == nil)
    }

    @Test("A newly ready model is verified immediately instead of waiting for cadence")
    func readinessRecoveryForcesCanary() async {
        let probe = Probe(
            availability: .available,
            results: [.modelNotReady, .completed(1)])
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: probe,
            now: start)

        var snapshot = await engine.check(now: start, forceFunctional: true)
        #expect(snapshot.phase == .unavailable)
        await probe.setAvailability(.unavailable(.modelNotReady))
        snapshot = await engine.check(now: start.addingTimeInterval(10))
        #expect(snapshot.phase == .unavailable)
        await probe.setAvailability(.available)
        snapshot = await engine.check(now: start.addingTimeInterval(20))
        #expect(snapshot.phase == .healthy)
        #expect(await probe.callCount() == 2)
    }

    @Test("A personal latency baseline identifies a large slowdown")
    func slowdown() async {
        let probe = Probe(results: [
            .completed(1), .completed(1.1), .completed(0.9), .completed(9)
        ])
        let engine = AppleModelHealthEngine(
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true),
            probe: probe,
            now: start)
        for offset in [0.0, 901, 1_802] {
            _ = await engine.check(now: start.addingTimeInterval(offset), forceFunctional: true)
        }
        let snapshot = await engine.check(
            now: start.addingTimeInterval(2_703), forceFunctional: true)
        #expect(snapshot.phase == .slow)
        #expect(snapshot.failure == nil)
    }

    @Test("Settings reject energy-hostile intervals")
    func settingsValidation() {
        let tooFrequent = AppleModelMonitorSettings(
            functionalChecksEnabled: true,
            checkIntervalSeconds: 30)
        #expect(tooFrequent.validationIssues.contains(where: { $0.contains("5 minutes") }))
        #expect(AppleModelMonitorSettings().validationIssues.isEmpty)
    }

    @Test("Only confirmed Apple timeouts enter unified incident history")
    func incidentHistory() {
        var ledger = MonitorIncidentLedger()
        var snapshot = AppleModelHealthSnapshot(now: start)
        snapshot.availability = .available
        snapshot.phase = .verifying
        snapshot.failure = .timedOut
        snapshot.functionalCheckedAt = start
        snapshot.functionalSucceededAt = start
        #expect(ledger.observeAppleModel(snapshot: snapshot) == .none)
        #expect(ledger.incidents.isEmpty)

        snapshot.phase = .down
        snapshot.changedAt = start.addingTimeInterval(30)
        snapshot.functionalCheckedAt = start.addingTimeInterval(30)
        let opened = ledger.observeAppleModel(snapshot: snapshot)
        #expect(opened.incidentID != nil)
        #expect(ledger.incidents.first?.targetName == "Apple Intelligence")

        snapshot.phase = .healthy
        snapshot.failure = nil
        snapshot.functionalCheckedAt = start.addingTimeInterval(60)
        snapshot.functionalSucceededAt = start.addingTimeInterval(60)
        let recovered = ledger.observeAppleModel(snapshot: snapshot)
        #expect(recovered.incidentID == opened.incidentID)
        #expect(ledger.incidents.first?.resolution == .recovered)
    }

    @Test("Apple diagnostics retain health metadata but no generated content")
    func diagnosticsPrivacy() {
        var snapshot = AppleModelHealthSnapshot(now: start)
        snapshot.phase = .healthy
        snapshot.availability = .available
        snapshot.checkedAt = start
        snapshot.functionalCheckedAt = start
        snapshot.functionalSucceededAt = start
        snapshot.lastLatencySeconds = 1.25
        let report = AppleModelDiagnosticsText.report(
            snapshot: snapshot,
            settings: AppleModelMonitorSettings(functionalChecksEnabled: true))
        #expect(report.contains("Last latency seconds: 1.250"))
        #expect(report.contains("Generated content retained: no"))
        #expect(!report.contains("Reply with only"))
        #expect(!report.contains("ready"))
    }
}
