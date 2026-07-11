// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import Testing
@testable import HearthMonitor

@Suite("Monitor history store")
struct MonitorHistoryStoreTests {
    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hearth-monitor-history-\(UUID())", isDirectory: true)
    }

    @Test("History round-trips with private permissions")
    func roundTrip() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MonitorHistoryStore(directoryURL: directory)
        let incident = MonitorIncident(
            targetID: UUID(), targetName: "GPU", startedAt: Date(),
            lastObservedAt: Date(), cause: "Down", inferenceLevel: true)
        let ledger = MonitorIncidentLedger(incidents: [incident])
        try store.save(ledger)
        #expect(store.load().ledger == ledger)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("Corrupt history is preserved and nonfatal")
    func corruption() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MonitorHistoryStore(directoryURL: directory)
        let original = Data("broken".utf8)
        try original.write(to: store.fileURL)
        let loaded = store.load()
        #expect(loaded.ledger.incidents.isEmpty)
        #expect(loaded.problem != nil)
        #expect(try Data(contentsOf: store.fileURL) == original)
    }
}
