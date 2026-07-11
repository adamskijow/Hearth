// SPDX-License-Identifier: MIT

import Foundation

/// How applying a config change affects a running menubar supervisor.
///
/// Notification, pressure-alert, heartbeat, and control-endpoint settings are
/// independent services around the engine, so they can be replaced without
/// touching the runner. Everything else remains deliberately conservative: if a
/// setting feeds the runner or engine, rebuild supervision rather than pretending
/// a value was applied when the existing engine still holds the old one.
public enum ConfigReloadImpact: String, Sendable, Equatable {
    case none
    case live
    case restart

    public static func between(_ old: HearthConfig, _ new: HearthConfig) -> ConfigReloadImpact {
        guard old != new else { return .none }

        var oldCore = old
        var newCore = new
        oldCore.copyLiveReloadFields(from: newCore)
        newCore.copyLiveReloadFields(from: oldCore)
        return oldCore == newCore ? .live : .restart
    }
}

private extension HearthConfig {
    /// Make the receiver's live-reloadable fields match `other`. Comparing the
    /// resulting configs tells us whether anything outside that safe set changed.
    mutating func copyLiveReloadFields(from other: HearthConfig) {
        localNotifications = other.localNotifications
        ntfyTopic = other.ntfyTopic
        ntfyServer = other.ntfyServer
        webhookURL = other.webhookURL
        memoryAlertPercent = other.memoryAlertPercent
        thermalAlerts = other.thermalAlerts
        notificationsPaused = other.notificationsPaused
        heartbeatURL = other.heartbeatURL
        heartbeatIntervalSeconds = other.heartbeatIntervalSeconds
        controlEnabled = other.controlEnabled
        controlHost = other.controlHost
        controlPort = other.controlPort
        controlToken = other.controlToken
        controlTokens = other.controlTokens
        controlStatusTokens = other.controlStatusTokens
    }
}
