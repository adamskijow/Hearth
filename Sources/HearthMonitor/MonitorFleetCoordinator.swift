// SPDX-License-Identifier: MIT

import Combine
import Foundation
import HearthMonitorCore
import SupervisorCore

/// Main-actor runtime for all configured endpoints. Each target owns one engine
/// and one cancellable loop. Automatic checks are lightly staggered and a manual
/// Check All runs sequentially, preventing a fleet of inference probes from
/// competing for the same GPU at once.
@MainActor
final class MonitorFleetCoordinator: ObservableObject {
    @Published private(set) var targets: [MonitorTarget] = []
    @Published private(set) var snapshots: [UUID: MonitorSnapshot] = [:]
    @Published private(set) var checkingTargetIDs: Set<UUID> = []

    var onSnapshot: ((MonitorTarget, MonitorSnapshot?, MonitorSnapshot) -> Void)?
    var onTargetRemoved: ((UUID) -> Void)?

    private final class Entry {
        var target: MonitorTarget
        let engine: MonitorEngine
        var loop: Task<Void, Never>?

        init(target: MonitorTarget, http: any HTTPClient) {
            self.target = target
            engine = MonitorEngine(target: target, http: http)
        }
    }

    private let httpFactory: @MainActor (MonitorTarget) -> any HTTPClient
    private let automaticallySchedules: Bool
    private var entries: [UUID: Entry] = [:]
    private var systemIsAwake = true

    init(http: any HTTPClient, automaticallySchedules: Bool = true) {
        self.httpFactory = { _ in http }
        self.automaticallySchedules = automaticallySchedules
    }

    init(httpFactory: @escaping @MainActor (MonitorTarget) -> any HTTPClient,
         automaticallySchedules: Bool = true) {
        self.httpFactory = httpFactory
        self.automaticallySchedules = automaticallySchedules
    }

    func apply(_ updatedTargets: [MonitorTarget],
               reloadCredentialsFor: Set<UUID> = []) {
        let incomingIDs = Set(updatedTargets.map(\.id))
        let removedIDs = entries.keys.filter { !incomingIDs.contains($0) }
        for id in removedIDs {
            entries[id]?.loop?.cancel()
            entries[id] = nil
            snapshots[id] = nil
            checkingTargetIDs.remove(id)
            onTargetRemoved?(id)
        }

        for (index, target) in updatedTargets.enumerated() {
            if let existing = entries[target.id],
               !reloadCredentialsFor.contains(target.id),
               existing.target.monitorBehaviorEquals(target) {
                // A name-only edit must not make a healthy runner look unchecked.
                existing.target = target
                continue
            }
            if let existing = entries[target.id], existing.target.isEnabled && !target.isEnabled {
                onTargetRemoved?(target.id)
            }
            entries[target.id]?.loop?.cancel()
            let entry = Entry(target: target, http: httpFactory(target))
            entries[target.id] = entry
            var initial = MonitorSnapshot(
                targetID: target.id,
                now: Date(),
                deepProbeConfigured: target.normalizedProbeModel != nil)
            if !target.isEnabled { initial.phase = .paused }
            snapshots[target.id] = initial
            if automaticallySchedules && target.isEnabled {
                startLoop(entry, initialDelay: Double(index) * 0.5)
            }
        }
        targets = updatedTargets
    }

    func checkAllNow() {
        let ids = targets.filter(\.isEnabled).map(\.id)
        Task { [weak self] in
            for id in ids {
                guard let self, !Task.isCancelled else { return }
                await self.checkNow(targetID: id, forceDeepProbe: true)
            }
        }
    }

    func checkNow(targetID: UUID, forceDeepProbe: Bool = true) async {
        guard let entry = entries[targetID], entry.target.isEnabled,
              !checkingTargetIDs.contains(targetID) else { return }
        checkingTargetIDs.insert(targetID)
        defer { checkingTargetIDs.remove(targetID) }
        let prior = snapshots[targetID]
        let snapshot = await entry.engine.check(
            forceDeepProbe: forceDeepProbe,
            deepProbeAllowed: forceDeepProbe || deepProbeEnergyAllowed)
        guard entries[targetID] === entry, !Task.isCancelled else { return }
        snapshots[targetID] = snapshot
        onSnapshot?(entry.target, prior, snapshot)
    }

    func stop() {
        for entry in entries.values { entry.loop?.cancel() }
        entries.removeAll()
        checkingTargetIDs.removeAll()
    }

    func setSystemAwake(_ awake: Bool) {
        systemIsAwake = awake
        if awake {
            // Shallow checks run continuously, but waking should not leave a
            // long interval before connectivity is re-established.
            let ids = targets.filter(\.isEnabled).map(\.id)
            Task { [weak self] in
                for id in ids { await self?.checkNow(targetID: id, forceDeepProbe: false) }
            }
        }
    }

    var overallPhase: MonitorPhase? {
        let enabledTargets = targets.filter(\.isEnabled)
        guard !enabledTargets.isEmpty else { return targets.isEmpty ? nil : .paused }
        let current = enabledTargets.compactMap { snapshots[$0.id] }
        if current.contains(where: { $0.phase == .down }) { return .down }
        if current.count < enabledTargets.count || current.contains(where: { $0.phase == .checking }) {
            return .checking
        }
        if current.contains(where: { $0.phase == .busy && $0.failure != nil }) { return .checking }
        if current.contains(where: { $0.phase == .busy }) { return .busy }
        return .healthy
    }

    private var deepProbeEnergyAllowed: Bool {
        guard systemIsAwake, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return false
        default: return true
        }
    }

    private func startLoop(_ entry: Entry, initialDelay: TimeInterval) {
        entry.loop = Task { [weak self, weak entry] in
            guard let entry else { return }
            if initialDelay > 0 {
                do { try await Task.sleep(for: .seconds(initialDelay)) }
                catch { return }
            }
            while !Task.isCancelled {
                await self?.checkNow(targetID: entry.target.id, forceDeepProbe: false)
                guard !Task.isCancelled else { return }
                let interval = max(2, entry.target.probeIntervalSeconds)
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }
}

private extension MonitorTarget {
    func monitorBehaviorEquals(_ other: MonitorTarget) -> Bool {
        id == other.id
            && runner == other.runner
            && isEnabled == other.isEnabled
            && scheme == other.scheme
            && host == other.host
            && port == other.port
            && authentication == other.authentication
            && probeModel == other.probeModel
            && probeIntervalSeconds == other.probeIntervalSeconds
            && probeTimeoutSeconds == other.probeTimeoutSeconds
            && deepProbeIntervalSeconds == other.deepProbeIntervalSeconds
            && deepProbeTimeoutSeconds == other.deepProbeTimeoutSeconds
            && failureThreshold == other.failureThreshold
            && modelRefreshIntervalSeconds == other.modelRefreshIntervalSeconds
    }
}
