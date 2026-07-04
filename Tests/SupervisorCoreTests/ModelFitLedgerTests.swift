// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The pure model-fit ledger: which resident model, if any, keeps running the
/// Mac out of memory across incidents in a window.
struct ModelFitLedgerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func oneIncidentDoesNotFlagAtTheDefaultThreshold() {
        var ledger = ModelFitLedger(threshold: 2, window: 1800)
        ledger.record(models: ["big:70b"], at: t0)
        #expect(ledger.flaggedModels(now: t0) == [])
    }

    @Test func twoIncidentsInWindowFlagTheModel() {
        var ledger = ModelFitLedger(threshold: 2, window: 1800)
        ledger.record(models: ["big:70b"], at: t0)
        ledger.record(models: ["big:70b"], at: t0.addingTimeInterval(300))
        #expect(ledger.flaggedModels(now: t0.addingTimeInterval(300)) == ["big:70b"])
    }

    @Test func incidentsAgeOutOfTheWindow() {
        var ledger = ModelFitLedger(threshold: 2, window: 1800)
        ledger.record(models: ["big:70b"], at: t0)
        ledger.record(models: ["big:70b"], at: t0.addingTimeInterval(300))
        // Long after the window, both incidents have aged out.
        #expect(ledger.flaggedModels(now: t0.addingTimeInterval(1800 + 400)) == [])
    }

    @Test func theCommonModelAcrossIncidentsIsFlagged() {
        // big is resident in both incidents; small only in one. Only big crosses.
        var ledger = ModelFitLedger(threshold: 2, window: 1800)
        ledger.record(models: ["big:70b", "small:1b"], at: t0)
        ledger.record(models: ["big:70b"], at: t0.addingTimeInterval(60))
        #expect(ledger.flaggedModels(now: t0.addingTimeInterval(60)) == ["big:70b"])
    }

    @Test func modelsAlwaysLoadedTogetherBothFlag() {
        var ledger = ModelFitLedger(threshold: 2, window: 1800)
        ledger.record(models: ["a", "b"], at: t0)
        ledger.record(models: ["a", "b"], at: t0.addingTimeInterval(60))
        #expect(ledger.flaggedModels(now: t0.addingTimeInterval(60)) == ["a", "b"])
    }

    @Test func zeroThresholdDisablesTheLedger() {
        var ledger = ModelFitLedger(threshold: 0, window: 1800)
        ledger.record(models: ["big:70b"], at: t0)
        ledger.record(models: ["big:70b"], at: t0.addingTimeInterval(60))
        #expect(ledger.flaggedModels(now: t0.addingTimeInterval(60)) == [])
    }

    @Test func emptyResidentSetsRecordNothing() {
        var ledger = ModelFitLedger(threshold: 1, window: 1800)
        ledger.record(models: [], at: t0)
        #expect(ledger.flaggedModels(now: t0) == [])
    }
}
