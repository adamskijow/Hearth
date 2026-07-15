// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

struct MonitorSettingsLoadResult: Sendable {
    var settings: MonitorSettings
    var problem: String?
}

protocol MonitorSettingsPersisting: Sendable {
    func load() -> MonitorSettingsLoadResult
    func save(_ settings: MonitorSettings) throws
}

/// JSON settings inside the app's sandbox container. A corrupt or future-version
/// file is never silently overwritten at launch; the app opens with an actionable
/// warning and only writes after the user explicitly saves.
struct MonitorSettingsStore: MonitorSettingsPersisting, Sendable {
    enum StoreError: LocalizedError {
        case unsupportedSchema(Int)
        case invalidTarget(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "These settings use schema version \(version), which this version of Hearth Monitor does not understand."
            case .invalidTarget(let issue): return issue
            }
        }
    }

    let directoryURL: URL
    var fileURL: URL { directoryURL.appendingPathComponent("settings.json", isDirectory: false) }

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

    func load() -> MonitorSettingsLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MonitorSettingsLoadResult(settings: MonitorSettings(), problem: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            var settings = try JSONDecoder().decode(MonitorSettings.self, from: data)
            guard settings.schemaVersion <= MonitorSettings.currentSchemaVersion else {
                throw StoreError.unsupportedSchema(settings.schemaVersion)
            }
            settings.normalizeSelection()
            guard Set(settings.targets.map(\.id)).count == settings.targets.count else {
                throw StoreError.invalidTarget("Saved runners contain duplicate identities.")
            }
            if let issue = settings.targets.lazy.compactMap({ $0.validationIssues.first }).first {
                throw StoreError.invalidTarget("A saved runner is invalid: \(issue)")
            }
            if let issue = settings.appleModel.validationIssues.first {
                throw StoreError.invalidTarget("Apple on-device model monitoring is invalid: \(issue)")
            }
            return MonitorSettingsLoadResult(settings: settings, problem: nil)
        } catch {
            return MonitorSettingsLoadResult(
                settings: MonitorSettings(),
                problem: "Saved settings could not be loaded. The original file was left unchanged. \(error.localizedDescription)")
        }
    }

    func save(_ settings: MonitorSettings) throws {
        guard Set(settings.targets.map(\.id)).count == settings.targets.count else {
            throw StoreError.invalidTarget("Saved runners contain duplicate identities.")
        }
        if let issue = settings.targets.lazy.compactMap({ $0.validationIssues.first }).first {
            throw StoreError.invalidTarget(issue)
        }
        if let issue = settings.appleModel.validationIssues.first {
            throw StoreError.invalidTarget(issue)
        }
        var current = settings
        current.schemaVersion = MonitorSettings.currentSchemaVersion
        current.normalizeSelection()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(current)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }
}
