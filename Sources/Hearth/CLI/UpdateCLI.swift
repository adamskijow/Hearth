// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// `hearth update`: a supervised upgrade of the runner and of Hearth itself.
/// Ollama's own auto-update is unreliable on an unattended Mac (no off switch,
/// and "Restart to update" needs a person at the screen), so this runs the
/// package manager in the user's terminal and then makes sure a running Hearth
/// actually adopts the new binary instead of serving the old one from memory
/// forever. When Hearth was installed with the Homebrew cask, a second phase
/// upgrades Hearth too, so the command's name tells the whole truth.
enum UpdateCLI {
    private final class AcceptanceBox: @unchecked Sendable {
        var value = false
    }

    static func run() -> Never {
        let config = ConfigStore.load().config
        guard let brew = firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) else {
            FileHandle.standardError.write(Data(
                "Hearth: Homebrew was not found. Update Ollama and Hearth however they were installed, then use Restart in Hearth's menu.\n".utf8))
            exit(1)
        }

        var ok = true
        if config.runnerKind == .ollama {
            ok = updateOllama(config: config, brew: brew)
        } else {
            print("`hearth update` upgrades Homebrew Ollama only; update \(config.runnerKind.displayName) with its own updater, then use Restart in Hearth's menu.")
        }
        ok = updateHearthItself(brew: brew) && ok
        exit(ok ? 0 : 1)
    }

    /// Phase 1: the runner. Returns false when brew failed or the binary vanished.
    private static func updateOllama(config: HearthConfig, brew: String) -> Bool {
        let binary = config.selectedBinaryPath
        let before = fingerprint(binary)
        print("Hearth update: running `brew upgrade ollama`\u{2026}")
        let status = runInherited(brew, ["upgrade", "ollama"])
        guard status == 0 else {
            FileHandle.standardError.write(Data(
                "Hearth: brew exited with status \(status); nothing was adopted.\n".utf8))
            return false
        }

        let after = fingerprint(binary)
        guard after != nil else {
            FileHandle.standardError.write(Data(
                "Hearth: the runner binary is missing at \(binary) after the upgrade; check brew's output before restarting anything.\n".utf8))
            return false
        }
        guard after != before else {
            print("Ollama is already up to date; nothing for Hearth to adopt.")
            return true
        }

        print("Ollama was upgraded on disk.")
        if config.restartOnBinaryChange {
            print("restartOnBinaryChange is on: a running Hearth adopts the new binary at its next probe, within seconds.")
            return true
        }
        if config.controlEnabled, let token = config.controlToken, !token.isEmpty,
           postRestart(host: config.controlHost, port: config.controlPort, token: token) {
            print("Asked the running Hearth to restart the runner onto the new binary; `hearth status` confirms it.")
            return true
        }
        print("""
        To serve the new version, restart the runner from Hearth's menu (Restart),
        or reload a running Hearth with `killall -HUP Hearth`. Setting
        restartOnBinaryChange in the config makes future upgrades adopt themselves.
        """)
        return true
    }

    /// Phase 2: Hearth itself, when the Homebrew cask installed it. A source or
    /// hand install is said out loud rather than skipped silently, so the
    /// command never half-lies about what it covered.
    private static func updateHearthItself(brew: String) -> Bool {
        guard FileManager.default.fileExists(atPath: SelfUpdate.caskroomPath(forBrew: brew)) else {
            print("Hearth itself was not installed with the Homebrew cask; update it the way it was installed (for a source build: git pull, then scripts/install-app.sh).")
            return true
        }
        // The dev binary runs without a bundle, so the version can be absent.
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .map { " (currently \($0))" } ?? ""
        let appBinary = "/Applications/Hearth.app/Contents/MacOS/Hearth"
        let before = fingerprint(appBinary)
        print("Hearth update: running `brew upgrade --cask hearth`\(version)\u{2026}")
        let status = runInherited(brew, ["upgrade", "--cask", "hearth"])
        guard status == 0 else {
            FileHandle.standardError.write(Data(
                "Hearth: brew exited with status \(status) upgrading the Hearth cask.\n".utf8))
            return false
        }
        if fingerprint(appBinary) == before {
            print("Hearth is already up to date\(version).")
        } else {
            print("""
            Hearth was upgraded on disk. A running instance keeps the old binary
            until it relaunches: restart the login agent with
              launchctl kickstart -k gui/$(id -u)/com.hearth.headless
            or quit and reopen the menubar app.
            """)
        }
        return true
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Size, mtime, and inode of the executable, following symlinks: a Homebrew
    /// binary is a Cellar symlink that retargets on upgrade.
    private static func fingerprint(_ path: String) -> String? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        return "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_ino)"
    }

    /// Run a command wired to this terminal, so brew's own output and prompts
    /// reach the user directly.
    private static func runInherited(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("Hearth: could not run \(path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// POST /restart on the local control endpoint. Returns true on a 202.
    private static func postRestart(host: String, port: Int, token: String) -> Bool {
        guard let url = URL(string: "http://\(urlAuthorityHost(for: host)):\(port)/restart") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        let accepted = AcceptanceBox()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            accepted.value = (response as? HTTPURLResponse)?.statusCode == 202
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        return accepted.value
    }
}
