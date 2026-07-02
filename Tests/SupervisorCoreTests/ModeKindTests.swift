// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

/// ModeKind is the one place the config `mode` string is resolved and the mode's
/// user-facing vocabulary lives. These pin the mapping (including the historic
/// default-to-managed for anything unknown, matching `HearthConfig.isManaged`)
/// and the phrases the status line and Preferences picker route through.
struct ModeKindTests {
    @Test func mapsStringsAndDefaultsUnknownToManaged() {
        for raw in ["managed", "Managed", "MANAGED", "", "not-a-mode"] {
            #expect(ModeKind(fromConfigString: raw) == .managed)
        }
        for raw in ["attached", "Attached", "ATTACHED"] {
            #expect(ModeKind(fromConfigString: raw) == .attached)
        }
    }

    @Test func exposesTheUserFacingVocabulary() {
        #expect(ModeKind.managed.statusPhrase == "started by Hearth")
        #expect(ModeKind.attached.statusPhrase == "watched (started elsewhere)")
        #expect(ModeKind.managed.pickerLabel == "Hearth starts runner")
        #expect(ModeKind.attached.pickerLabel == "Watch existing runner")
    }

    @Test func configExposesModeKindConsistentWithIsManaged() {
        let managed = HearthConfig(mode: "managed")
        let attached = HearthConfig(mode: "attached")
        let unknown = HearthConfig(mode: "banana")
        #expect(managed.modeKind == .managed && managed.isManaged)
        #expect(attached.modeKind == .attached && !attached.isManaged)
        #expect(unknown.modeKind == .managed && unknown.isManaged)
    }
}
