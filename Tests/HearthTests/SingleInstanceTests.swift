// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import Hearth

/// SingleInstance behavior when the lock file cannot be created (an unwritable
/// support directory). It must not fail open silently: the menubar app proceeds
/// best-effort, but the headless daemon reports failure so its caller exits rather
/// than falling into a respawn fight over the runner.
struct SingleInstanceTests {
    /// A config path inside a directory that does not exist, so open(O_CREAT) on
    /// `<path>.lock` fails with ENOENT and the acquire hits the fd < 0 branch.
    private var unwritableConfig: URL {
        URL(fileURLWithPath: "/nonexistent-hearth-\(UUID().uuidString)/deeper/config.json")
    }

    @Test func menubarProceedsBestEffortWhenLockCannotBeCreated() {
        #expect(SingleInstance.acquire(configPath: unwritableConfig, wait: false) == true)
    }

    @Test func headlessFailsWhenLockCannotBeCreated() {
        // wait:true returns immediately here (the fd < 0 branch is before the
        // blocking flock), so this cannot hang.
        #expect(SingleInstance.acquire(configPath: unwritableConfig, wait: true) == false)
    }
}
