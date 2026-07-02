// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// `hearth update`: a supervised runner upgrade. Ollama's own auto-update is
/// unreliable on an unattended Mac (no off switch, and "Restart to update"
/// needs a person at the screen), so this runs the package manager in the
/// user's terminal and then makes sure a running Hearth actually adopts the
/// new binary instead of serving the old one from memory forever.
enum UpdateCLI {
    static func run() -> Never {
        let config = ConfigStore.load().config
        guard config.runnerKind == .ollama else {
            FileHandle.standardError.write(Data(
                "Hearth: `hearth update` upgrades Homebrew Ollama only for now. Update \(config.runnerKind.displayName) with its own updater, then use Restart in Hearth's menu.\n".utf8))
            exit(1)
        }
        guard let brew = firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) else {
            FileHandle.standardError.write(Data(
                "Hearth: Homebrew was not found. Update Ollama however you installed it, then use Restart in Hearth's menu.\n".utf8))
            exit(1)
        }

        let binary = config.selectedBinaryPath
        let before = fingerprint(binary)
        print("Hearth update: running `brew upgrade ollama`\u{2026}")
        let status = runInherited(brew, ["upgrade", "ollama"])
        guard status == 0 else {
            FileHandle.standardError.write(Data(
                "Hearth: brew exited with status \(status); nothing was adopted.\n".utf8))
            exit(status == 0 ? 1 : status)
        }

        let after = fingerprint(binary)
        guard after != nil else {
            FileHandle.standardError.write(Data(
                "Hearth: the runner binary is missing at \(binary) after the upgrade; check brew's output before restarting anything.\n".utf8))
            exit(1)
        }
        guard after != before else {
            print("Ollama is already up to date; nothing for Hearth to adopt.")
            exit(0)
        }

        print("Ollama was upgraded on disk.")
        if config.restartOnBinaryChange {
            print("restartOnBinaryChange is on: a running Hearth adopts the new binary at its next probe, within seconds.")
            exit(0)
        }
        if config.controlEnabled, let token = config.controlToken, !token.isEmpty,
           postRestart(host: config.controlHost, port: config.controlPort, token: token) {
            print("Asked the running Hearth to restart the runner onto the new binary; `hearth status` confirms it.")
            exit(0)
        }
        print("""
        To serve the new version, restart the runner from Hearth's menu (Restart),
        or reload a running Hearth with `killall -HUP Hearth`. Setting
        restartOnBinaryChange in the config makes future upgrades adopt themselves.
        """)
        exit(0)
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
        var accepted = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            accepted = (response as? HTTPURLResponse)?.statusCode == 202
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        return accepted
    }
}
