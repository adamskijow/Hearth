// SPDX-License-Identifier: MIT

import Foundation

/// Writes Hearth's on-disk state so only its owner can read it. The config file
/// holds the control token and the ntfy topic (both bearer secrets), and the
/// state files reveal the runner's identity and recovery history, so none of
/// them should be world-readable. Files are written 0600 inside a 0700
/// directory, matching what the daemon install script already does for the
/// daemon config, so the app no longer relies on that script to harden its own
/// user-written files.
///
/// Every step is best-effort. A chmod that fails (for example, a non-owner
/// process reading a root-owned daemon config) must never break reading or
/// writing, so the permission tightening is layered on top of a normal write
/// rather than gating it.
enum SecureFile {
    /// Atomically write `data` to `url`, then tighten the file to 0600 and its
    /// containing directory to 0700. Returns whether the write itself succeeded;
    /// the permission tightening is best-effort and never fails the call.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Tighten an already-present file to 0600, retro-hardening one an older
    /// version left world-readable. A no-op when the file is absent or not owned
    /// by this process (the chmod simply fails and is swallowed).
    static func harden(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Prepare a log or state file that other code writes through a FileHandle or
    /// launchd. The file may be empty for now, but it should still be owner-only
    /// before anything sensitive-adjacent is appended to it.
    static func prepareFile(_ url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
