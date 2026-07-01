// SPDX-License-Identifier: MIT

import Foundation
@testable import Hearth

/// Shared on-disk isolation for the whole HearthTests run. Every suite touches
/// `scratch` in its init, which relocates `runner-state.json` into a throwaway
/// directory before anything spawns, so these tests never read or clobber the
/// user's real support directory (and a real Hearth's orphan sweep never sees
/// the test children).
enum TestIsolation {
    static let scratch: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearthTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        RunnerStateStore.urlOverride = dir.appendingPathComponent("runner-state.json")
        return dir
    }()

    /// A fresh path under the scratch directory.
    static func path(_ name: String) -> URL {
        scratch.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}

/// Poll until `condition` holds or `timeout` passes. Returns whether it held.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// True when no process group with this id exists any more.
func groupIsGone(_ pgid: pid_t) -> Bool {
    killpg(pgid, 0) == -1 && errno == ESRCH
}
