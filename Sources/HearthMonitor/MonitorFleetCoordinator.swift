// SPDX-License-Identifier: MIT

import Combine
import Foundation
import HearthMonitorCore
import SupervisorCore

/// Main-actor runtime for all configured endpoints. Each target owns one engine
/// and one cancellable loop; checks run concurrently across targets but never
/// overlap for the same target.
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

    private let http: any HTTPClient
    private let automaticallySchedules: Bool
    private var entries: [UUID: Entry] = [:]

    init(http: any HTTPClient, automaticallySchedules: Bool = true) {
        self.http = http
        self.automaticallySchedules = automaticallySchedules
    }

    func apply(_ updatedTargets: [MonitorTarget]) {
        let incomingIDs = Set(updatedTargets.map(\.id))
        let removedIDs = entries.keys.filter { !incomingIDs.contains($0) }
        for id in removedIDs {
            entries[id]?.loop?.cancel()
            entries[id] = nil
            snapshots[id] = nil
            checkingTargetIDs.remove(id)
            onTargetRemoved?(id)
        }

        for target in updatedTargets {
            if let existing = entries[target.id], existing.target.monitorBehaviorEquals(target) {
                // A name-only edit must not make a healthy runner look unchecked.
                existing.target = target
                continue
            }
            entries[target.id]?.loop?.cancel()
            let entry = Entry(target: target, http: http)
            entries[target.id] = entry
            snapshots[target.id] = MonitorSnapshot(
                targetID: target.id,
                now: Date(),
                deepProbeConfigured: target.normalizedProbeModel != nil)
            if automaticallySchedules { startLoop(entry) }
        }
        targets = updatedTargets
    }

    func checkAllNow() {
        for target in targets {
            Task { [weak self] in
                await self?.checkNow(targetID: target.id, forceDeepProbe: true)
            }
        }
    }

    func checkNow(targetID: UUID, forceDeepProbe: Bool = true) async {
        guard let entry = entries[targetID], !checkingTargetIDs.contains(targetID) else { return }
        checkingTargetIDs.insert(targetID)
        defer { checkingTargetIDs.remove(targetID) }
        let prior = snapshots[targetID]
        let snapshot = await entry.engine.check(forceDeepProbe: forceDeepProbe)
        guard entries[targetID] === entry, !Task.isCancelled else { return }
        snapshots[targetID] = snapshot
        onSnapshot?(entry.target, prior, snapshot)
    }

    func stop() {
        for entry in entries.values { entry.loop?.cancel() }
        entries.removeAll()
        checkingTargetIDs.removeAll()
    }

    var overallPhase: MonitorPhase? {
        guard !targets.isEmpty else { return nil }
        let current = targets.compactMap { snapshots[$0.id] }
        if current.contains(where: { $0.phase == .down }) { return .down }
        if current.count < targets.count || current.contains(where: { $0.phase == .checking }) {
            return .checking
        }
        if current.contains(where: { $0.phase == .busy && $0.failure != nil }) { return .checking }
        if current.contains(where: { $0.phase == .busy }) { return .busy }
        return .healthy
    }

    private func startLoop(_ entry: Entry) {
        entry.loop = Task { [weak self, weak entry] in
            guard let entry else { return }
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
            && scheme == other.scheme
            && host == other.host
            && port == other.port
            && probeModel == other.probeModel
            && probeIntervalSeconds == other.probeIntervalSeconds
            && probeTimeoutSeconds == other.probeTimeoutSeconds
            && deepProbeIntervalSeconds == other.deepProbeIntervalSeconds
            && deepProbeTimeoutSeconds == other.deepProbeTimeoutSeconds
            && failureThreshold == other.failureThreshold
            && modelRefreshIntervalSeconds == other.modelRefreshIntervalSeconds
    }
}
