// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The POSIX identity a spawned runner can be dropped to, resolved from a
/// username. Used only by the root daemon's optional privilege drop: Hearth stays
/// root (to keep the reboot capability) while the runner it spawns runs as this
/// lower-privileged account, so a runner or malicious-model compromise does not
/// land as root.
public struct RunnerUserCredentials: Sendable, Equatable {
    public let uid: uid_t
    public let gid: gid_t
    /// The account's supplementary groups, so the dropped runner keeps the group
    /// memberships (device/GPU access, shared data) it would have on login.
    public let supplementaryGroups: [gid_t]

    public init(uid: uid_t, gid: gid_t, supplementaryGroups: [gid_t]) {
        self.uid = uid
        self.gid = gid
        self.supplementaryGroups = supplementaryGroups
    }

    /// Resolve a username to its uid, primary gid, and supplementary groups from
    /// the password database. Returns nil if the account does not exist. Reads the
    /// account database only; no side effects, so it is safe to call before a fork.
    public static func resolve(username: String) -> RunnerUserCredentials? {
        var pwd = passwd()
        var storage = [CChar](repeating: 0, count: 8192)
        var result: UnsafeMutablePointer<passwd>? = nil
        let rc = getpwnam_r(username, &pwd, &storage, storage.count, &result)
        guard rc == 0, result != nil else { return nil }
        let uid = pwd.pw_uid
        let gid = pwd.pw_gid

        // Supplementary groups. getgrouplist fills an int array and, when the
        // supplied array is too small, sets the count to the number needed so we
        // can retry once with a right-sized buffer.
        var count: Int32 = 64
        var raw = [Int32](repeating: 0, count: Int(count))
        if getgrouplist(username, Int32(bitPattern: gid), &raw, &count) == -1, count > 0 {
            raw = [Int32](repeating: 0, count: Int(count))
            _ = getgrouplist(username, Int32(bitPattern: gid), &raw, &count)
        }
        let groups = raw.prefix(Int(max(0, count))).map { gid_t(bitPattern: $0) }
        return RunnerUserCredentials(uid: uid, gid: gid, supplementaryGroups: Array(groups))
    }
}
