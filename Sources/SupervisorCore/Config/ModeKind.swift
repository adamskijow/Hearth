// SPDX-License-Identifier: MIT

import Foundation

/// The supervision mode, resolved from the config `mode` string. This is the one
/// place the mode's user-facing vocabulary lives: the status line, the Preferences
/// picker, and diagnostics all route through a kind instead of re-phrasing
/// managed/attached in each file. Anything unrecognized resolves to managed,
/// matching `HearthConfig.isManaged`'s historic default, so behavior is unchanged.
public enum ModeKind: String, CaseIterable, Sendable {
    case managed
    case attached

    public init(fromConfigString raw: String) {
        self = raw.lowercased() == "attached" ? .attached : .managed
    }

    /// Every accepted config `mode` string. Used by the doctor check that warns on
    /// an unrecognized value, which the kind mapping itself cannot express since it
    /// defaults anything unknown to managed.
    public static let knownConfigStrings: [String] = ["managed", "attached"]

    /// Plain-words phrase for status lines: what the mode means, not its name.
    public var statusPhrase: String {
        switch self {
        case .managed: return "started by Hearth"
        case .attached: return "watched (started elsewhere)"
        }
    }

    /// Label for the Preferences mode picker.
    public var pickerLabel: String {
        switch self {
        case .managed: return "Hearth starts runner"
        case .attached: return "Watch existing runner"
        }
    }
}
