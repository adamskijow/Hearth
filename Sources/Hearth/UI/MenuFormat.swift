// SPDX-License-Identifier: MIT

import AppKit
import SupervisorCore

/// AppKit-specific presentation for the menubar: the SF Symbol name and tint
/// color per phase. The text formatting lives in `StatusText` in core, where it
/// is unit tested.
enum MenuFormat {
    static func symbolName(for phase: SupervisorPhase) -> String {
        switch phase {
        case .stopped: return "moon.zzz"
        case .starting: return "hourglass"
        case .healthy: return "flame.fill"
        case .down: return "clock.arrow.circlepath"        // not serving, waiting out the backoff
        case .restarting: return "arrow.triangle.2.circlepath" // actively cycling
        case .failing: return "exclamationmark.triangle.fill"
        }
    }

    static func tint(for phase: SupervisorPhase) -> NSColor? {
        switch phase {
        case .stopped: return .secondaryLabelColor
        case .starting: return .systemBlue
        case .healthy: return nil // template, adapts to the menubar
        case .down, .restarting: return .systemOrange
        case .failing: return .systemRed
        }
    }
}
