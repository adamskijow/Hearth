// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct PressureEvaluatorTests {
    private let thresholds = PressureThresholds(memoryAlertPercent: 90, thermalAlerts: true)

    private func metrics(memory: Double?, thermal: ThermalState = .nominal) -> SystemMetrics {
        SystemMetrics(thermal: thermal, memoryUsedFraction: memory)
    }

    @Test func memoryAlertsOnCrossingAndClearsWithHysteresis() {
        var state = PressureMonitorState()

        // Below the threshold: nothing.
        #expect(PressureEvaluator.evaluate(metrics(memory: 0.85), thresholds: thresholds, state: &state).isEmpty)

        // Crosses 90%: one alert, and it latches.
        #expect(PressureEvaluator.evaluate(metrics(memory: 0.92), thresholds: thresholds, state: &state)
                == [.memoryHigh(percent: 92)])
        #expect(state.memoryAlerted)

        // Still high: no repeat.
        #expect(PressureEvaluator.evaluate(metrics(memory: 0.95), thresholds: thresholds, state: &state).isEmpty)

        // Eases only below the clear level (80%), not just under 90.
        #expect(PressureEvaluator.evaluate(metrics(memory: 0.85), thresholds: thresholds, state: &state).isEmpty)
        #expect(PressureEvaluator.evaluate(metrics(memory: 0.78), thresholds: thresholds, state: &state)
                == [.memoryEased(percent: 78)])
        #expect(!state.memoryAlerted)
    }

    @Test func thermalAlertsOnElevationAndEases() {
        var state = PressureMonitorState()
        #expect(PressureEvaluator.evaluate(metrics(memory: nil, thermal: .fair), thresholds: thresholds, state: &state).isEmpty)
        #expect(PressureEvaluator.evaluate(metrics(memory: nil, thermal: .serious), thresholds: thresholds, state: &state)
                == [.thermalElevated("serious")])
        #expect(PressureEvaluator.evaluate(metrics(memory: nil, thermal: .critical), thresholds: thresholds, state: &state).isEmpty) // still elevated
        #expect(PressureEvaluator.evaluate(metrics(memory: nil, thermal: .nominal), thresholds: thresholds, state: &state)
                == [.thermalEased("nominal")])
    }

    @Test func disabledChannelsStaySilent() {
        var state = PressureMonitorState()
        let off = PressureThresholds(memoryAlertPercent: 0, thermalAlerts: false)
        #expect(PressureEvaluator.evaluate(metrics(memory: 0.99, thermal: .critical), thresholds: off, state: &state).isEmpty)
    }

    @Test func configMapsTheThresholds() {
        #expect(HearthConfig().pressureThresholds().memoryAlertPercent == 90)
        #expect(HearthConfig().pressureThresholds().thermalAlerts)
        let custom = HearthConfig(memoryAlertPercent: 0, thermalAlerts: false).pressureThresholds()
        #expect(custom.memoryAlertPercent == 0)
        #expect(!custom.thermalAlerts)
    }
}
