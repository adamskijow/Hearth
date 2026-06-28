// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct StatusTextTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: headline

    @Test func headlinePerPhase() {
        #expect(StatusText.headline(SupervisorState(phase: .stopped), now: t0) == "Stopped")
        #expect(StatusText.headline(SupervisorState(phase: .starting), now: t0) == "Starting\u{2026}")
        #expect(StatusText.headline(SupervisorState(phase: .healthy), now: t0) == "Healthy")
    }

    @Test func restartingShowsTheAttempt() {
        let s = SupervisorState(phase: .restarting, restartCount: 3)
        #expect(StatusText.headline(s, now: t0) == "Restarting (attempt 3)")
    }

    @Test func downAndFailingShowTheRetryCountdown() {
        let retryAt = t0.addingTimeInterval(4)
        let down = SupervisorState(phase: .down, nextRetryAt: retryAt)
        #expect(StatusText.headline(down, now: t0) == "Down (retry in 4s)")

        let failing = SupervisorState(phase: .failing, nextRetryAt: retryAt)
        #expect(StatusText.headline(failing, now: t0) == "Crash loop (retry in 4s)")
    }

    @Test func downWithoutARetryTimeHasNoSuffix() {
        #expect(StatusText.headline(SupervisorState(phase: .down), now: t0) == "Down")
    }

    @Test func retryNeverGoesNegative() {
        let past = t0.addingTimeInterval(-10)
        let s = SupervisorState(phase: .down, nextRetryAt: past)
        #expect(StatusText.headline(s, now: t0) == "Down (retry in 0s)")
    }

    // MARK: contextLine

    @Test func contextLineFoldsRunnerModeUptimeAndRestarts() {
        let s = SupervisorState(phase: .healthy, healthySince: t0, restartCount: 2)
        let now = t0.addingTimeInterval(125) // 2m 5s
        let line = StatusText.contextLine(s, runnerName: "Ollama", managed: true, now: now)
        #expect(line == "Ollama, managed \u{00B7} Up 2m 5s \u{00B7} 2 restarts")
    }

    @Test func contextLineSingularRestartAndAttachedMode() {
        let s = SupervisorState(phase: .healthy, healthySince: t0, restartCount: 1)
        let line = StatusText.contextLine(s, runnerName: "LM Studio", managed: false, now: t0)
        #expect(line == "LM Studio, attached \u{00B7} Up 0s \u{00B7} 1 restart")
    }

    @Test func contextLineOmitsUptimeWhenNotHealthy() {
        let s = SupervisorState(phase: .down) // no healthySince
        #expect(StatusText.contextLine(s, runnerName: "Ollama", managed: true, now: t0) == "Ollama, managed")
    }

    // MARK: duration / bytes / model

    @Test func durationScales() {
        #expect(StatusText.duration(45) == "45s")
        #expect(StatusText.duration(125) == "2m 5s")
        #expect(StatusText.duration(3_725) == "1h 2m 5s")
    }

    @Test func modelShowsSizeWhenKnown() {
        #expect(StatusText.model(ResidentModel(name: "qwen2.5:0.5b")) == "qwen2.5:0.5b")
        let sized = StatusText.model(ResidentModel(name: "llama", sizeBytes: 5_000_000_000))
        #expect(sized.hasPrefix("llama ("))
        #expect(sized.hasSuffix(")"))
    }

    // MARK: describe

    @Test func describesEvents() {
        #expect(StatusText.describe(.started) == "Started")
        #expect(StatusText.describe(.recovered) == "Recovered")
        #expect(StatusText.describe(.restarted(attempt: 2)) == "Restarted (attempt 2)")
        #expect(StatusText.describe(.restartScheduled(attempt: 1, backoff: 4)) == "Restart scheduled (attempt 1, in 4s)")
        #expect(StatusText.describe(.stopped) == "Stopped")
    }
}
