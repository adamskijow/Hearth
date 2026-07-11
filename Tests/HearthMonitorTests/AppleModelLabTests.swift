// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore
import Testing
@testable import HearthMonitor

@MainActor
@Suite("Private Apple model lab")
struct AppleModelLabTests {
    actor FakeRunner: AppleModelLabRunning {
        var availabilityValue: AppleModelAvailability = .available
        var result = AppleModelLabResult.completed(
            text: "Healthy means responding correctly.",
            metrics: AppleModelLabMetrics(
                timeToFirstOutputSeconds: 0.2,
                totalSeconds: 0.5,
                responseTokens: 6))
        var requests: [AppleModelLabRequest] = []
        var waitForStop = false
        var stopRequested = false
        var stopContinuation: CheckedContinuation<Void, Never>?

        func availability() -> AppleModelAvailability { availabilityValue }

        func run(
            _ request: AppleModelLabRequest,
            onPartial: @escaping @Sendable (String, TimeInterval?) async -> Void
        ) async -> AppleModelLabResult {
            requests.append(request)
            await onPartial("Healthy means", 0.2)
            if waitForStop {
                if !stopRequested {
                    await withCheckedContinuation { stopContinuation = $0 }
                }
                return .stopped
            }
            await onPartial("Healthy means responding correctly.", 0.2)
            return result
        }

        func stop() {
            stopRequested = true
            let continuation = stopContinuation
            stopContinuation = nil
            continuation?.resume()
        }

        func requestCount() -> Int { requests.count }
        func setWaitForStop() { waitForStop = true }
        func setAvailability(_ value: AppleModelAvailability) { availabilityValue = value }
    }

    @Test("Streaming output and exact metrics remain separate from health state")
    func streamingResult() async {
        let runner = FakeRunner()
        var activity: [Bool] = []
        let model = AppleModelLabModel(
            runner: runner,
            availability: .available,
            onActivityChanged: { activity.append($0) })

        model.run()
        #expect(await waitUntil { model.phase == .idle })
        #expect(model.output == "Healthy means responding correctly.")
        #expect(model.metrics?.timeToFirstOutputSeconds == 0.2)
        #expect(model.metrics?.totalSeconds == 0.5)
        #expect(model.metrics?.responseTokens == 6)
        #expect(activity == [true, false])
        #expect(await runner.requestCount() == 1)
    }

    @Test("Stop waits for the runner and does not turn cancellation into failure")
    func stopIsNeutral() async {
        let runner = FakeRunner()
        await runner.setWaitForStop()
        let model = AppleModelLabModel(runner: runner, availability: .available)

        model.run()
        #expect(await waitUntil { model.output == "Healthy means" })
        model.stop()
        #expect(model.phase == .stopping)
        #expect(await waitUntil { model.phase == .idle })
        #expect(model.message?.hasPrefix("Generation stopped") == true)
    }

    @Test("Unavailable Apple Intelligence blocks generation with actionable text")
    func unavailableBlocksRun() async {
        let runner = FakeRunner()
        await runner.setAvailability(.unavailable(.appleIntelligenceNotEnabled))
        let model = AppleModelLabModel(
            runner: runner,
            availability: .unavailable(.appleIntelligenceNotEnabled))

        #expect(!model.canRun)
        model.run()
        #expect(model.message?.contains("System Settings") == true)
        #expect(await runner.requestCount() == 0)
    }

    @Test("Inputs are bounded and normalized before model use")
    func requestBounds() {
        var request = AppleModelLabRequest(
            instructions: "  concise  ",
            prompt: "  hello  ",
            sampling: .varied,
            temperature: 9,
            maximumResponseTokens: 10_000)
        #expect(request.validationMessage == nil)
        request = request.normalized
        #expect(request.instructions == "concise")
        #expect(request.prompt == "hello")
        #expect(request.temperature == 2)
        #expect(request.maximumResponseTokens == 512)
    }

    @Test("Closing the lab clears prompt and generated content from memory")
    func closeClearsSession() async {
        let runner = FakeRunner()
        let model = AppleModelLabModel(runner: runner, availability: .available)
        model.prompt = "private prompt"
        model.run()
        #expect(await waitUntil { model.phase == .idle })

        model.endSession()
        #expect(model.output.isEmpty)
        #expect(model.metrics == nil)
        #expect(model.prompt == AppleModelLabModel.defaultPrompt)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
