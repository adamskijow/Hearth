// SPDX-License-Identifier: MIT

import Foundation

/// Installs (and removes) a per-user LaunchAgent that runs Hearth headless at
/// login and keeps it alive, so an app that depends on a local runner can rely on
/// Hearth being up with a single command instead of hand-rolling a plist. This is
/// the user-level counterpart to the root LaunchDaemon in deploy/: it needs no
/// sudo, runs while you are logged in, and is safe to run even if the menubar app
/// also launches (the single-instance guard makes one of them stand by).
enum AgentInstaller {
    static let label = "com.hearth.headless"

    private static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func install() -> Never {
        let result = performInstall()
        for line in result.lines { print(line) }
        exit(result.ok ? 0 : 1)
    }

    /// Do the install and return the outcome plus the lines to show, so `setup`
    /// can drive it and keep going rather than exiting.
    static func performInstall() -> (ok: Bool, lines: [String]) {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let config = AppPaths.configFile.path
        let outLog = AppPaths.logDirectory.appendingPathComponent("headless.out.log").path
        let errLog = AppPaths.logDirectory.appendingPathComponent("headless.err.log").path

        // Build the plist from a dictionary so paths are escaped correctly.
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--headless"],
            "EnvironmentVariables": ["HEARTH_CONFIG": config],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": outLog,
            "StandardErrorPath": errLog,
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            SecureFile.prepareFile(URL(fileURLWithPath: outLog))
            SecureFile.prepareFile(URL(fileURLWithPath: errLog))
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return (false, ["Could not write \(plistURL.path): \(error.localizedDescription)"])
        }

        // Reload cleanly: bootout any existing copy (ignore failure), then bootstrap.
        let domain = "gui/\(getuid())"
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let loaded = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])

        var lines = [
            "Installed the Hearth headless LaunchAgent.",
            "  runs:   \(exe) --headless",
            "  config: \(config)",
            "  plist:  \(plistURL.path)",
            "  logs:   \(outLog)",
        ]
        if loaded.ok {
            lines.append("Loaded and started; Hearth now runs headless at login and stays alive.")
        } else {
            lines.append("Wrote the plist, but launchctl bootstrap reported:")
            lines.append("  \(loaded.output)")
            lines.append("Load it yourself with: launchctl bootstrap \(domain) \(plistURL.path)")
        }
        if exe.contains("/.build/") || exe.contains("/DerivedData/") {
            lines.append("Note: this points at a build directory, which is not stable. Install Hearth")
            lines.append("(make install or the cask) and run `hearth install-agent` from there.")
        }
        lines.append("If the menubar app also launches, that is fine: whichever starts first supervises")
        lines.append("and the other stands by (single-instance guard). Remove this with `hearth uninstall-agent`.")
        return (loaded.ok, lines)
    }

    static func uninstall() -> Never {
        let domain = "gui/\(getuid())"
        let booted = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let existed = FileManager.default.fileExists(atPath: plistURL.path)
        try? FileManager.default.removeItem(at: plistURL)
        if existed || booted.ok {
            print("Removed the Hearth headless LaunchAgent (\(label)).")
        } else {
            print("No Hearth headless LaunchAgent was installed.")
        }
        exit(0)
    }

    // MARK: - helpers

    private static func run(_ tool: String, _ args: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
