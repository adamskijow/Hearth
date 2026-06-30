// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Standard on disk locations and config loading. Config is JSON (chosen over
/// TOML to keep the dependency set empty: JSON decodes with Foundation alone).
enum AppPaths {
    /// An override that moves all of Hearth's on-disk state and logs under one
    /// directory, so a throwaway, demo, or test instance is fully isolated from a
    /// real one. Without it, the support and log locations are fixed under the
    /// user's home and shared across instances (including `runner-state.json`,
    /// whose orphan sweep would otherwise reach another instance's runner). The
    /// single-instance lock is already config-keyed; this isolates the data too.
    private static var dataDirectoryOverride: URL? {
        guard let override = ProcessInfo.processInfo.environment["HEARTH_DATA_DIR"],
              !override.isEmpty else { return nil }
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// ~/Library/Application Support/Hearth, or `HEARTH_DATA_DIR` when set.
    static var supportDirectory: URL {
        if let override = dataDirectoryOverride { return override }
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

    /// ~/Library/Logs/Hearth, or `HEARTH_DATA_DIR`/logs when set.
    static var logDirectory: URL {
        if let override = dataDirectoryOverride {
            return override.appendingPathComponent("logs", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
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

        let exists = fm.fileExists(atPath: url.path)
        // A present but unreadable file is read as empty Data so it fails to parse
        // and surfaces as a problem, rather than nil (first run) which would
        // overwrite it with a template. Detection only seeds the first-run path.
        let contents: Data? = exists ? ((try? Data(contentsOf: url)) ?? Data()) : nil
        let detected: String? = exists ? nil : RunnerLocator.locate(HearthConfig().runner)

        let resolution = ConfigLoading.resolve(fileContents: contents, configPath: url.path, detectedBinary: detected)
        if resolution.createdDefault {
            save(resolution.config)
        }
        return ConfigLoad(
            config: resolution.config,
            note: resolution.note,
            isProblem: resolution.isProblem,
            createdDefault: resolution.createdDefault
        )
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
