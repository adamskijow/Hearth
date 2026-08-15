// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct ManagedStartAdmissionTests {
    @Test func managedLaunchBlocksForEitherOwnershipConflict() {
        #expect(ManagedStartAdmission.shouldBlock(
            mode: "managed", hasPreexistingRunner: true, hasCompetingManager: false))
        #expect(ManagedStartAdmission.shouldBlock(
            mode: "managed", hasPreexistingRunner: false, hasCompetingManager: true))
        #expect(!ManagedStartAdmission.shouldBlock(
            mode: "managed", hasPreexistingRunner: false, hasCompetingManager: false))
    }

    @Test func attachedLaunchNeverClaimsOwnership() {
        #expect(!ManagedStartAdmission.shouldBlock(
            mode: "attached", hasPreexistingRunner: true, hasCompetingManager: true))
    }
}
