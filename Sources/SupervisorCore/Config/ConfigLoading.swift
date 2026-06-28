// SPDX-License-Identifier: MIT

import Foundation

/// The outcome of resolving the config, so the UI can tell apart a clean load, a
/// first-run template, and a parse failure (which is a setup problem to surface
/// loudly rather than silently revert to defaults).
public struct ConfigResolution: Sendable, Equatable {
    public var config: HearthConfig
    public var note: String?
    public var isProblem: Bool
    public var createdDefault: Bool

    public init(config: HearthConfig, note: String?, isProblem: Bool, createdDefault: Bool) {
        self.config = config
        self.note = note
        self.isProblem = isProblem
        self.createdDefault = createdDefault
    }
}

/// Pure config resolution. The app layer does the file I/O (existence, read,
/// write, binary detection) and hands the raw bytes here; this decides what to
/// do with them. Keeping the decision pure makes the first-run, clean-load, and
/// parse-failure paths testable without a filesystem.
public enum ConfigLoading {
    /// Resolve the config from the file's raw contents.
    ///
    /// `fileContents` is nil only when the file does not exist (first run). A file
    /// that exists but cannot be read should be passed as the bytes actually read
    /// (possibly empty), so it fails to parse and surfaces as a problem rather
    /// than being silently overwritten with a template. `detectedBinary` is the
    /// runner binary found on disk, used only to seed the first-run template.
    public static func resolve(fileContents: Data?, configPath: String, detectedBinary: String?) -> ConfigResolution {
        guard let data = fileContents else {
            var defaults = HearthConfig()
            if let detectedBinary {
                defaults.ollamaBinaryPath = detectedBinary
            }
            return ConfigResolution(
                config: defaults,
                note: "Created a starter config at \(configPath)",
                isProblem: false,
                createdDefault: true
            )
        }

        do {
            let config = try JSONDecoder().decode(HearthConfig.self, from: data)
            return ConfigResolution(config: config, note: nil, isProblem: false, createdDefault: false)
        } catch {
            return ConfigResolution(
                config: HearthConfig(),
                note: "Config could not be read: \(error.localizedDescription). Fix it, then choose Reload Config.",
                isProblem: true,
                createdDefault: false
            )
        }
    }
}
