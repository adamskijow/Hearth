// SPDX-License-Identifier: MIT

import Foundation
import Darwin

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

    /// Write an exported secret into a caller-chosen folder. Unlike Hearth's
    /// state directories, that folder may be shared and must retain its mode.
    /// mkstemp creates a private file before any bytes are written; rename then
    /// replaces the destination atomically without following an existing symlink.
    static func writePrivateOutput(_ data: Data, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        } catch { return false }
        var template = Array(directory.appendingPathComponent(".hearth-private-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return false }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { unlink(temporary) }
        // A shared macOS folder can grant inherited ACL access even at 0600.
        // Remove those grants through the open descriptor before writing data.
        guard let acl = acl_init(0) else { close(fd); return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd(fd, acl) == 0, fchmod(fd, 0o600) == 0 else { close(fd); return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return rename(temporary, url.path) == 0
        } catch {
            try? handle.close()
            return false
        }
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
