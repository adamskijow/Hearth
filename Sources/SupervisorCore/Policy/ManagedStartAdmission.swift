// SPDX-License-Identifier: MIT

import Foundation

/// The managed-launch ownership gate. Kept pure so first-launch ordering cannot
/// regress into spawning (or exposing control) before a collision is resolved.
public enum ManagedStartAdmission {
    public static func shouldBlock(
        mode: String,
        hasPreexistingRunner: Bool,
        hasCompetingManager: Bool
    ) -> Bool {
        mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "managed"
            && (hasPreexistingRunner || hasCompetingManager)
    }
}
