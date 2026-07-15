// SPDX-License-Identifier: MIT

import Combine
import Foundation
import HearthMonitorCore
import SupervisorCore

enum FullHearthBridgePhase: String, Sendable, Equatable {
    case checking
    case connected
    case unavailable
    case unauthorized
    case credentialMissing
    case runnerMismatch
}

struct FullHearthBridgeSnapshot: Sendable, Equatable {
    var targetID: UUID
    var phase: FullHearthBridgePhase
    var checkedAt: Date?
    var message: String
    var status: FullHearthStatus?

    init(targetID: UUID,
         phase: FullHearthBridgePhase = .checking,
         checkedAt: Date? = nil,
         message: String = "Checking full Hearth…",
         status: FullHearthStatus? = nil) {
        self.targetID = targetID
        self.phase = phase
        self.checkedAt = checkedAt
        self.message = message
        self.status = status
    }

    var hasManagedRecovery: Bool { phase == .connected && status?.isManaged == true }
    var usesLeastPrivilege: Bool? {
        status?.credentialAccess.map { $0 == "statusOnly" }
    }
}

@MainActor
final class FullHearthBridgeCoordinator: ObservableObject {
    @Published private(set) var snapshots: [UUID: FullHearthBridgeSnapshot] = [:]
    @Published private(set) var checkingTargetIDs: Set<UUID> = []
    var onUpdate: (() -> Void)?

    private final class Entry {
        var target: MonitorTarget
        var loop: Task<Void, Never>?
        init(target: MonitorTarget) { self.target = target }
    }

    private let client: FullHearthClient
    private let secrets: any MonitorSecretStoring
    private let automaticallySchedules: Bool
    private var entries: [UUID: Entry] = [:]

    init(client: FullHearthClient,
         secrets: any MonitorSecretStoring,
         automaticallySchedules: Bool = true) {
        self.client = client
        self.secrets = secrets
        self.automaticallySchedules = automaticallySchedules
    }

    func apply(_ targets: [MonitorTarget]) {
        let paired = targets.filter { $0.isEnabled && $0.fullHearth != nil }
        let incoming = Set(paired.map(\.id))
        for id in entries.keys.filter({ !incoming.contains($0) }) {
            entries[id]?.loop?.cancel()
            entries[id] = nil
            snapshots[id] = nil
            checkingTargetIDs.remove(id)
        }
        for target in paired {
            if let existing = entries[target.id], existing.target.fullHearth == target.fullHearth {
                existing.target = target
                continue
            }
            entries[target.id]?.loop?.cancel()
            let entry = Entry(target: target)
            entries[target.id] = entry
            snapshots[target.id] = FullHearthBridgeSnapshot(targetID: target.id)
            if automaticallySchedules { startLoop(entry) }
        }
        onUpdate?()
    }

    func refresh(targetID: UUID) async {
        guard let entry = entries[targetID],
              let endpoint = entry.target.fullHearth,
              !checkingTargetIDs.contains(targetID) else { return }
        checkingTargetIDs.insert(targetID)
        defer { checkingTargetIDs.remove(targetID) }
        let priorStatus = snapshots[targetID]?.status
        do {
            guard let token = try secrets.token(for: targetID), !token.isEmpty else {
                publish(FullHearthBridgeSnapshot(
                    targetID: targetID,
                    phase: .credentialMissing,
                    checkedAt: Date(),
                    message: "The Keychain status token is missing. Reconnect full Hearth.",
                    status: priorStatus), entry: entry)
                return
            }
            let status = try await client.status(endpoint: endpoint, token: token)
            guard entries[targetID] === entry, !Task.isCancelled else { return }
            let statusKind = status.runner.lowercased()
            let runnerMatches = RunnerKind.knownConfigStrings.contains(statusKind)
                && RunnerKind(fromConfigString: statusKind) == entry.target.runnerKind
            if !runnerMatches {
                publish(FullHearthBridgeSnapshot(
                    targetID: targetID,
                    phase: .runnerMismatch,
                    checkedAt: Date(),
                    message: "Full Hearth reports \(status.runner), but this target is \(entry.target.runnerKind.displayName).",
                    status: status), entry: entry)
                return
            }
            let message: String
            if status.isManaged == true {
                message = status.rebootOnWedge == true
                    ? "Full Hearth manages runner recovery and has reboot escalation configured."
                    : "Full Hearth manages and automatically restarts this runner."
            } else if status.isManaged == false {
                message = "Full Hearth is also attached-only; automatic process recovery is not active."
            } else {
                message = "Connected to an older full Hearth; recovery mode is not reported."
            }
            publish(FullHearthBridgeSnapshot(
                targetID: targetID,
                phase: .connected,
                checkedAt: Date(),
                message: message,
                status: status), entry: entry)
        } catch let error as FullHearthClientError {
            let phase: FullHearthBridgePhase = error == .unauthorized ? .unauthorized : .unavailable
            publish(FullHearthBridgeSnapshot(
                targetID: targetID,
                phase: phase,
                checkedAt: Date(),
                message: error.localizedDescription,
                status: priorStatus), entry: entry)
        } catch {
            publish(FullHearthBridgeSnapshot(
                targetID: targetID,
                phase: .unavailable,
                checkedAt: Date(),
                message: error.localizedDescription,
                status: priorStatus), entry: entry)
        }
    }

    func stop() {
        for entry in entries.values { entry.loop?.cancel() }
        entries.removeAll()
        checkingTargetIDs.removeAll()
    }

    private func publish(_ snapshot: FullHearthBridgeSnapshot, entry: Entry) {
        guard entries[snapshot.targetID] === entry else { return }
        snapshots[snapshot.targetID] = snapshot
        onUpdate?()
    }

    private func startLoop(_ entry: Entry) {
        entry.loop = Task { [weak self, weak entry] in
            guard let entry else { return }
            while !Task.isCancelled {
                await self?.refresh(targetID: entry.target.id)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }
}
