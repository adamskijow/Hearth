// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct RebootEscalationTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func policy(enabled: Bool = true) -> RebootPolicy {
        RebootPolicy(enabled: enabled, escalateAfterSeconds: 600, minIntervalSeconds: 1800, maxPerDay: 3)
    }

    private func decide(phase: SupervisorPhase,
                        failingSince: Date?,
                        everHealthy: Bool,
                        history: RebootHistory = RebootHistory(),
                        now: Date,
                        enabled: Bool = true,
                        bootedAt: Date? = nil) -> RebootDecision {
        RebootEscalation.decide(policy: policy(enabled: enabled), phase: phase, failingSince: failingSince,
                                everHealthyThisSession: everHealthy, history: history, now: now,
                                systemBootedAt: bootedAt)
    }

    @Test func disabledNeverReboots() {
        let r = decide(phase: .failing, failingSince: t0, everHealthy: true,
                       now: t0.addingTimeInterval(100_000), enabled: false)
        #expect(r == .wait)
    }

    @Test func neverHealthyMeansSetupFailureNotAWedge() {
        // Failing for a long time, but it was never serving: a wrong binary path
        // or bad config must not trigger reboots.
        let r = decide(phase: .failing, failingSince: t0, everHealthy: false, now: t0.addingTimeInterval(100_000))
        #expect(r == .wait)
    }

    @Test func waitsUntilFailingLongEnough() {
        #expect(decide(phase: .failing, failingSince: t0, everHealthy: true, now: t0.addingTimeInterval(300)) == .wait)
        #expect(decide(phase: .failing, failingSince: t0, everHealthy: true, now: t0.addingTimeInterval(601)) == .reboot)
    }

    @Test func onlyTheFailingPhaseEscalates() {
        for phase in [SupervisorPhase.healthy, .down, .restarting, .starting, .stopped] {
            #expect(decide(phase: phase, failingSince: t0, everHealthy: true, now: t0.addingTimeInterval(100_000)) == .wait)
        }
    }

    @Test func aRecentRebootThatDidNotHelpDoesNotLoop() {
        // We rebooted 10 minutes ago and are wedged again: the reboot did not fix
        // it, so escalate to a human, do not reboot again.
        let history = RebootHistory(recoveryReboots: [t0.addingTimeInterval(-600)])
        let r = decide(phase: .failing, failingSince: t0.addingTimeInterval(-700), everHealthy: true,
                       history: history, now: t0.addingTimeInterval(100))
        #expect(r == .exhausted)
    }

    @Test func anOldRebootDoesNotBlockANewOne() {
        // A reboot two hours ago (past the 30-minute min interval) does not block a
        // fresh escalation.
        let history = RebootHistory(recoveryReboots: [t0.addingTimeInterval(-7200)])
        let r = decide(phase: .failing, failingSince: t0, everHealthy: true,
                       history: history, now: t0.addingTimeInterval(700))
        #expect(r == .reboot)
    }

    @Test func theDailyCapIsEnforced() {
        // Three reboots already today (spaced past the min interval): the cap is
        // reached, so the next escalation asks for a human.
        let history = RebootHistory(recoveryReboots: [
            t0.addingTimeInterval(-3 * 3600),
            t0.addingTimeInterval(-2 * 3600),
            t0.addingTimeInterval(-1 * 3600)
        ])
        let r = decide(phase: .failing, failingSince: t0.addingTimeInterval(-3600), everHealthy: true,
                       history: history, now: t0.addingTimeInterval(700))
        #expect(r == .exhausted)
    }

    @Test func rebootsOlderThanADayDoNotCountTowardTheCap() {
        let history = RebootHistory(recoveryReboots: [
            t0.addingTimeInterval(-90_000),  // > 24h ago
            t0.addingTimeInterval(-80_000),
            t0.addingTimeInterval(-70_000)
        ])
        let r = decide(phase: .failing, failingSince: t0, everHealthy: true,
                       history: history, now: t0.addingTimeInterval(700))
        #expect(r == .reboot)
    }

    @Test func aRecentSystemBootDoesNotLoopEvenWithEmptyHistory() {
        // The reboot history was lost across the reboot (empty file), but the Mac
        // booted only 5 minutes ago: a reboot just happened and did not clear the
        // wedge, so the boot-time backstop blocks a loop even with no history.
        let looped = decide(phase: .failing, failingSince: t0.addingTimeInterval(-700),
                            everHealthy: true, now: t0, bootedAt: t0.addingTimeInterval(-300))
        #expect(looped == .exhausted)
        // Booted two hours ago (past the 30-minute min interval): the backstop does
        // not block a legitimate fresh reboot.
        let fresh = decide(phase: .failing, failingSince: t0.addingTimeInterval(-700),
                           everHealthy: true, now: t0, bootedAt: t0.addingTimeInterval(-7200))
        #expect(fresh == .reboot)
    }

    @Test func historyRoundTripsThroughJSON() throws {
        let original = RebootHistory(recoveryReboots: [t0, t0.addingTimeInterval(3600)])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RebootHistory.self, from: data) == original)
    }

    @Test func configMapsAndClampsTheRebootPolicy() throws {
        #expect(!HearthConfig().rebootPolicy().enabled)   // off by default

        // Decoded from JSON with deliberately reboot-happy values, which are
        // clamped to safe floors.
        let json = Data(#"{"rebootOnWedge":true,"rebootEscalateAfterSeconds":1,"rebootMinIntervalSeconds":1,"rebootMaxPerDay":0}"#.utf8)
        let policy = try JSONDecoder().decode(HearthConfig.self, from: json).rebootPolicy()
        #expect(policy.enabled)
        #expect(policy.escalateAfterSeconds >= 60)
        #expect(policy.minIntervalSeconds >= 300)
        #expect(policy.maxPerDay >= 1)
    }
}
