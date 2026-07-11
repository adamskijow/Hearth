// SPDX-License-Identifier: MIT

import Combine
import Foundation
import HearthMonitorCore

/// Main-actor scheduling and energy policy around the pure Apple health engine.
/// Availability remains visible while functional inference pauses for sleep,
/// Low Power Mode, or serious thermal pressure.
@MainActor
final class AppleModelHealthCoordinator: ObservableObject {
    @Published private(set) var snapshot = AppleModelHealthSnapshot()
    @Published private(set) var isChecking = false

    var onSnapshot: ((AppleModelHealthSnapshot?, AppleModelHealthSnapshot) -> Void)?

    private let probe: any AppleModelProbing
    private var engine: AppleModelHealthEngine?
    private var settings = AppleModelMonitorSettings()
    private var loop: Task<Void, Never>?
    private var systemIsAwake = true
    private var manualLabActive = false

    init(probe: any AppleModelProbing) {
        self.probe = probe
    }

    func apply(_ updated: AppleModelMonitorSettings) {
        if updated == settings, engine != nil, updated.enabled { return }
        settings = updated
        guard updated.enabled else {
            stop()
            return
        }
        // Recreate only when Apple settings themselves change. This guarantees a
        // just-enabled canary cannot race an actor settings update, while saves
        // to alerts or runner configuration preserve the latency baseline.
        loop?.cancel()
        loop = nil
        snapshot = AppleModelHealthSnapshot()
        engine = AppleModelHealthEngine(settings: updated, probe: probe)
        startLoop()
    }

    func setSystemAwake(_ awake: Bool) {
        systemIsAwake = awake
        if awake, settings.enabled {
            Task { [weak self] in await self?.checkNow(forceFunctional: false) }
        }
    }

    func setManualLabActive(_ active: Bool) {
        manualLabActive = active
        if !active, settings.enabled {
            Task { [weak self] in await self?.checkNow(forceFunctional: false) }
        }
    }

    func checkNow(forceFunctional: Bool = true) async {
        guard let engine, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let prior = snapshot
        let next = await engine.check(
            forceFunctional: forceFunctional && !manualLabActive,
            functionalChecksAllowed: functionalChecksAllowed && !manualLabActive)
        guard !Task.isCancelled else { return }
        snapshot = next
        onSnapshot?(prior, next)
    }

    func stop() {
        loop?.cancel()
        loop = nil
        engine = nil
        isChecking = false
    }

    private var functionalChecksAllowed: Bool {
        guard systemIsAwake, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return true
        case .serious, .critical: return false
        @unknown default: return false
        }
    }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow(forceFunctional: false)
                do {
                    // Availability can change independently of the 15-minute
                    // functional cadence, so refresh its cheap public state once a minute.
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }
}
