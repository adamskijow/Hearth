// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// Samples system conditions with public APIs only (no root, no powermetrics):
/// the thermal state from ProcessInfo, system memory in use from the Mach VM
/// statistics, and the runner child's resident size from libproc. This is
/// observability to judge throttling and out of memory risk, not inference.
final class SystemMetricsProvider: MetricsProviding, @unchecked Sendable {
    private let runnerResidentBytes: @Sendable () -> Int64?

    init(runnerResidentBytes: @escaping @Sendable () -> Int64?) {
        self.runnerResidentBytes = runnerResidentBytes
    }

    func sample() -> SystemMetrics {
        SystemMetrics(
            thermal: Self.thermalState(),
            memoryUsedFraction: Self.memoryUsedFraction(),
            runnerResidentBytes: runnerResidentBytes()
        )
    }

    private static func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    private static func memoryUsedFraction() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Pressure-relevant pages only: active, wired, and compressed. Inactive
        // and cached pages are reclaimable, so excluding them is intentional. This
        // is an out-of-memory-risk signal, not Activity Monitor's "Memory Used",
        // and will read lower than that figure by design.
        let pageSize = UInt64(getpagesize())
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return min(1.0, Double(used) / Double(total))
    }
}
