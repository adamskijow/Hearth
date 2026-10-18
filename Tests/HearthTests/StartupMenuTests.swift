// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import Hearth

@MainActor
struct StartupMenuTests {
    @Test func menuOffersRecoveryBeforeEngineCanBeConfigured() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = NSMenu()
        // An invalid initial config leaves the engine components unavailable.
        // Users must still be able to fix the file, reload it, or quit.
        delegate.menuNeedsUpdate(menu)
        for title in ["Open Configuration…", "Reload Configuration", "Quit Hearth"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.isEnabled)
            #expect(item.target === delegate)
            #expect(item.action != nil)
        }
        #expect(menu.items.last?.keyEquivalent == "q")
    }
}
