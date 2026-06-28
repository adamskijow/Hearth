// SPDX-License-Identifier: MIT

import Foundation
import IOKit.pwr_mgt
import SupervisorCore

/// Holds an IOKit power assertion so the Mac does not idle sleep while the runner
/// is meant to be serving. The assertion is `PreventUserIdleSystemSleep`.
///
/// Scope: this prevents idle sleep. It does not defeat closed lid sleep on
/// battery, which needs a privileged system setting and is left for later.
final class IOKitPowerManager: PowerManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID = IOPMAssertionID(0)
    private var held = false
    private let reason: String

    init(reason: String = "Hearth is keeping the local LLM runner available") {
        self.reason = reason
    }

    func hold() {
        lock.withLock {
            guard !held else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                held = true
            }
        }
    }

    func release() {
        lock.withLock {
            guard held else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
            held = false
        }
    }
}
