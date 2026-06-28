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

    /// ~/Library/Logs/Hearth/ollama.log
    static var runnerLogFile: URL {
        logDirectory.appendingPathComponent("ollama.log")
    }
}

enum ConfigStore {
    /// Load the config from disk, or write a documented default template on first
    /// run and return the defaults. A malformed file is reported and the defaults
    /// are used rather than refusing to start.
    static func load() -> (config: HearthConfig, note: String?) {
        let fm = FileManager.default
        let url = AppPaths.configFile
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: url.path) else {
            let defaults = HearthConfig()
            writeTemplate(defaults, to: url)
            return (defaults, "Wrote a default config to \(url.path)")
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(HearthConfig.self, from: data)
            return (config, nil)
        } catch {
            return (HearthConfig(), "Config at \(url.path) could not be read (\(error.localizedDescription)); using defaults")
        }
    }

    private static func writeTemplate(_ config: HearthConfig, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: url)
    }
}
