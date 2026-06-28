// SPDX-License-Identifier: MIT

import Foundation
import ServiceManagement

/// Login item registration via SMAppService, so the agent autostarts at login.
///
/// This only works for a properly bundled, signed app. When run as a bare
/// executable (for example `swift run Hearth` during development), there is no
/// app bundle to register and the calls fail gracefully; the menubar reflects the
/// real status rather than pretending.
enum LoginItem {
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether registration is even possible here (there is an app bundle).
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    @discardableResult
    static func register() -> Bool {
        guard isAvailable else { return false }
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func unregister() -> Bool {
        guard isAvailable else { return false }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            return false
        }
    }
}
