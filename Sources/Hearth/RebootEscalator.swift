// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Watches the supervisor state and, when a wedge has survived process-level
/// recovery for long enough, escalates to a reboot per RebootEscalation's paranoid
/// policy. The decision is pure and tested in core; this thin glue tracks whether
/// the runner was ever healthy this session, loads and persists the reboot
/// history, announces, and pulls the trigger through the SystemControlling seam.
final class RebootEscalator {
    private let policy: RebootPolicy
    private let system: SystemControlling
    private let announce: (String) -> Void
    private var everHealthy = false
    private var announcedExhausted = false

    init(policy: RebootPolicy, system: SystemControlling, announce: @escaping (String) -> Void) {
        self.policy = policy
        self.system = system
        self.announce = announce
    }

    func observe(_ state: SupervisorState, now: Date = Date()) {
        if state.phase == .healthy {
            everHealthy = true
            announcedExhausted = false
        }
        guard policy.enabled else { return }

        switch RebootEscalation.decide(
            policy: policy,
            phase: state.phase,
            failingSince: state.failingSince,
            everHealthyThisSession: everHealthy,
            history: RebootHistoryStore.load(),
            now: now,
            systemBootedAt: system.bootedAt()
        ) {
        case .wait:
            break
        case .reboot:
            // Persist BEFORE rebooting: the reboot will not return, and the loop
            // guard must remember this attempt across the reboot.
            RebootHistoryStore.record(now)
            announce("Hearth is rebooting the Mac to recover a wedged runner that process restarts could not clear.")
            system.reboot()
        case .exhausted:
            if !announcedExhausted {
                announcedExhausted = true
                announce("Hearth could not recover the runner; a recovery reboot did not help, or the daily cap was reached. Manual attention is needed.")
            }
        }
    }
}
