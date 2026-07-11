// SPDX-License-Identifier: MIT

import Foundation
import ServiceManagement

enum MonitorLoginItem {
    enum State: Equatable {
        case off
        case on
        case requiresApproval
        case unavailable
    }

    @MainActor static var state: State {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .off
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    @MainActor static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
