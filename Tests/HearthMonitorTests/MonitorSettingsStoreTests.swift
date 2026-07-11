// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import Testing
@testable import HearthMonitor

@Suite("Monitor settings store")
struct MonitorSettingsStoreTests {
    private func scratch(_ name: String = UUID().uuidString) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hearth-monitor-tests-\(name)", isDirectory: true)
    }

    @Test("Missing settings are a clean first run")
    func missingFile() {
        let result = MonitorSettingsStore(directoryURL: scratch()).load()
        #expect(result.settings.targets.isEmpty)
        #expect(result.problem == nil)
    }

    @Test("Settings save atomically and reload")
    func saveAndLoad() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MonitorSettingsStore(directoryURL: directory)
        let target = MonitorTarget(name: "Local GPU")
        let settings = MonitorSettings(targets: [target], selectedTargetID: target.id)
        try store.save(settings)

        let loaded = store.load()
        #expect(loaded.problem == nil)
        #expect(loaded.settings == settings)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("A corrupt file remains untouched and reports a problem")
    func corruptFile() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MonitorSettingsStore(directoryURL: directory)
        let original = Data("not json".utf8)
        try original.write(to: store.fileURL)

        let loaded = store.load()
        #expect(loaded.settings.targets.isEmpty)
        #expect(loaded.problem != nil)
        #expect(try Data(contentsOf: store.fileURL) == original)
    }

    @Test("A future schema is preserved rather than downgraded")
    func futureSchema() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MonitorSettingsStore(directoryURL: directory)
        let original = Data(#"{"schemaVersion":99,"targets":[]}"#.utf8)
        try original.write(to: store.fileURL)

        let loaded = store.load()
        #expect(loaded.problem?.contains("version 99") == true)
        #expect(try Data(contentsOf: store.fileURL) == original)
    }

    @Test("Duplicate target identities cannot be saved")
    func duplicateIDs() {
        let target = MonitorTarget()
        let settings = MonitorSettings(targets: [target, target])
        let store = MonitorSettingsStore(directoryURL: scratch())
        var didThrow = false
        do {
            try store.save(settings)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }
}
