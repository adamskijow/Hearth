// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

struct MonitorHistoryLoadResult: Sendable {
    var ledger: MonitorIncidentLedger
    var problem: String?
}

struct MonitorHistoryStore: Sendable {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var ledger: MonitorIncidentLedger
    }

    static let currentSchemaVersion = 1
    let directoryURL: URL
    var fileURL: URL { directoryURL.appendingPathComponent("history.json", isDirectory: false) }

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.directoryURL = support.appendingPathComponent("Hearth Monitor", isDirectory: true)
        }
    }

    func load() -> MonitorHistoryLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MonitorHistoryLoadResult(ledger: MonitorIncidentLedger(), problem: nil)
        }
        do {
            let envelope = try JSONDecoder().decode(
                Envelope.self,
                from: Data(contentsOf: fileURL, options: .mappedIfSafe))
            guard envelope.schemaVersion <= Self.currentSchemaVersion else {
                return MonitorHistoryLoadResult(
                    ledger: MonitorIncidentLedger(),
                    problem: "Incident history was created by a newer version and was left unchanged.")
            }
            return MonitorHistoryLoadResult(ledger: envelope.ledger, problem: nil)
        } catch {
            return MonitorHistoryLoadResult(
                ledger: MonitorIncidentLedger(),
                problem: "Incident history could not be read and was left unchanged: \(error.localizedDescription)")
        }
    }

    func save(_ ledger: MonitorIncidentLedger) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(
            schemaVersion: Self.currentSchemaVersion,
            ledger: ledger))
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }
}
