// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import Hearth

/// A first launch creates the lock's parent directory. Neither entry point may
/// supervise without a lock if that directory or lock cannot be created.
@Suite(.serialized)
struct SingleInstanceTests {
    @Test(arguments: [false, true])
    func firstLaunchCreatesDirectoryAndExcludesASecondInstance(wait: Bool) throws {
        let directory = TestIsolation.path("first-launch").appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let config = directory.appendingPathComponent("config.json")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(SingleInstance.acquire(configPath: config, wait: wait))
        #expect(FileManager.default.fileExists(atPath: config.path + ".lock"))
        #expect(!SingleInstance.acquire(configPath: config, wait: false))
        #expect(!FileManager.default.fileExists(atPath: config.path))
    }

    @Test(arguments: [false, true])
    func refusesToSuperviseWhenLockCannotBeCreated(wait: Bool) throws {
        let obstruction = TestIsolation.path("regular-file")
        try Data("not a directory".utf8).write(to: obstruction)
        defer { try? FileManager.default.removeItem(at: obstruction) }
        let config = obstruction.appendingPathComponent("config.json")
        #expect(!SingleInstance.acquire(configPath: config, wait: wait))
    }
}
