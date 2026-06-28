// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

struct MetricsTests {
    @Test func thermalLabelsAndElevation() {
        #expect(ThermalState.nominal.label == "nominal")
        #expect(ThermalState.critical.label == "critical")
        #expect(!ThermalState.nominal.isElevated)
        #expect(!ThermalState.fair.isElevated)
        #expect(ThermalState.serious.isElevated)
        #expect(ThermalState.critical.isElevated)
    }

    @Test func memoryPercentRoundsAndClamps() {
        #expect(MetricsFormat.memoryPercent(0.423) == "42%")
        #expect(MetricsFormat.memoryPercent(0) == "0%")
        #expect(MetricsFormat.memoryPercent(1.5) == "100%")
        #expect(MetricsFormat.memoryPercent(-0.2) == "0%")
    }

    @Test func summaryCombinesAvailableMetrics() {
        let both = SystemMetrics(thermal: .fair, memoryUsedFraction: 0.5)
        #expect(MetricsFormat.summary(both) == "thermal fair, memory 50%")

        let memoryOnly = SystemMetrics(thermal: .unknown, memoryUsedFraction: 0.25)
        #expect(MetricsFormat.summary(memoryOnly) == "memory 25%")

        let thermalOnly = SystemMetrics(thermal: .serious, memoryUsedFraction: nil)
        #expect(MetricsFormat.summary(thermalOnly) == "thermal serious")

        let nothing = SystemMetrics(thermal: .unknown, memoryUsedFraction: nil)
        #expect(MetricsFormat.summary(nothing) == nil)
    }

    @Test func statusJSONIncludesMetricsWhenPresent() throws {
        let state = SupervisorState(phase: .healthy)
        let metrics = SystemMetrics(thermal: .serious, memoryUsedFraction: 0.42, runnerResidentBytes: 5_000_000_000)
        let data = ControlRouting.statusJSON(state, now: Date(timeIntervalSince1970: 0), metrics: metrics)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["thermal"] as? String == "serious")
        #expect(object["memoryUsedPercent"] as? Int == 42)
        #expect((object["runnerResidentBytes"] as? NSNumber)?.int64Value == 5_000_000_000)
    }

    @Test func statusJSONOmitsUnknownThermalAndAbsentMetrics() throws {
        let state = SupervisorState(phase: .healthy)
        // No metrics at all.
        let data = ControlRouting.statusJSON(state, now: Date(timeIntervalSince1970: 0))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["thermal"] == nil)
        #expect(object["memoryUsedPercent"] == nil)
        #expect(object["runnerResidentBytes"] == nil)
    }
}
