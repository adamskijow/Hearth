// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Resolving a username to the identity the root daemon's optional privilege drop
/// applies to the runner. Uses accounts present on every macOS install.
struct RunnerUserCredentialsTests {
    @Test func resolvesRootToUidZero() throws {
        let creds = try #require(RunnerUserCredentials.resolve(username: "root"))
        #expect(creds.uid == 0)
        #expect(creds.gid == 0)
        // getgrouplist always includes at least the primary group.
        #expect(creds.supplementaryGroups.contains(0))
        // Home and login name are captured so the drop can supply HOME/USER/LOGNAME.
        #expect(creds.name == "root")
        #expect(creds.home == "/var/root")
    }

    @Test func resolvesAKnownServiceAccount() throws {
        // "daemon" exists on every macOS install (uid 1).
        let creds = try #require(RunnerUserCredentials.resolve(username: "daemon"))
        #expect(creds.uid == 1)
        #expect(!creds.supplementaryGroups.isEmpty)
        #expect(creds.name == "daemon")
        #expect(!creds.home.isEmpty)
    }

    @Test func unknownAccountResolvesToNil() {
        #expect(RunnerUserCredentials.resolve(username: "no_such_hearth_account_zzzz") == nil)
        #expect(RunnerUserCredentials.resolve(username: "") == nil)
    }
}
