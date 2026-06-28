// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Standard on disk locations and config loading. Config is JSON (chosen over
/// TOML to keep the dependency set empty: JSON decodes with Foundation alone).
enum AppPaths {
    /// ~/Library/Application Support/Hearth
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Hearth", isDirectory: true)
    }

    /// The config file. Defaults to the standard support location, but the
    /// HEARTH_CONFIG environment variable overrides it (handy for running a
    /// throwaway config without touching the real one).
    static var configFile: URL {
        if let override = ProcessInfo.processInfo.environment["HEARTH_CONFIG"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return supportDirectory.appendingPathComponent("config.json")
    }

    /// ~/Library/Logs/Hearth
    static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Hearth", isDirectory: true)
    }

    /// ~/Library/Logs/Hearth/runner.log
    static var runnerLogFile: URL {
        logDirectory.appendingPathComponent("runner.log")
    }
}

/// The outcome of loading the config, so the UI can tell apart a clean load, a
/// first-run template, and a parse failure (which is a setup problem to surface
/// loudly rather than silently revert).
struct ConfigLoad {
    var config: HearthConfig
    var note: String?
    var isProblem: Bool
    var createdDefault: Bool
}

enum ConfigStore {
    /// Load the config from disk, writing a starter template on first run (with
    /// the runner binary auto detected so first run does not fail on a wrong
    /// path). A malformed file is flagged as a problem; the caller decides whether
    /// to keep its current settings rather than reverting.
    static func load() -> ConfigLoad {
        let fm = FileManager.default
        let url = AppPaths.configFile
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard fm.fileExists(atPath: url.path) else {
            var defaults = HearthConfig()
            if let detected = RunnerLocator.locate(defaults.runner) {
                defaults.ollamaBinaryPath = detected
            }
            save(defaults)
            return ConfigLoad(config: defaults, note: "Created a starter config at \(url.path)", isProblem: false, createdDefault: true)
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(HearthConfig.self, from: data)
            return ConfigLoad(config: config, note: nil, isProblem: false, createdDefault: false)
        } catch {
            return ConfigLoad(
                config: HearthConfig(),
                note: "Config could not be read: \(error.localizedDescription). Fix it, then choose Reload Config.",
                isProblem: true,
                createdDefault: false
            )
        }
    }

    /// Write the config to disk as pretty JSON.
    @discardableResult
    static func save(_ config: HearthConfig) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return false }
        try? FileManager.default.createDirectory(
            at: AppPaths.configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (try? data.write(to: AppPaths.configFile)) != nil
    }
}
