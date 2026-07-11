// SPDX-License-Identifier: MIT

import AppKit
import HearthMonitorCore

@MainActor
final class MonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let http = MonitorHTTPClient()
    private let store = MonitorSettingsStore()
    private let historyStore = MonitorHistoryStore()
    private let notifier = MonitorLocalNotifier()
    private let secrets = MonitorKeychainSecretStore()
    private lazy var fleet = MonitorFleetCoordinator(http: http)
    private lazy var fullHearthClient = FullHearthClient(http: http)
    private lazy var fullHearthBridge = FullHearthBridgeCoordinator(
        client: fullHearthClient,
        secrets: secrets)

    private var settings = MonitorSettings()
    private var settingsProblem: String?
    private var ledger = MonitorIncidentLedger()
    private var historyProblem: String?
    private var alertsInFlight: Set<String> = []
    private var alertRetryAfter: [String: Date] = [:]
    private var menuIsOpen = false

    private var editor: MonitorTargetEditorController?
    private var preferences: MonitorPreferencesController?
    private var historyController: MonitorHistoryController?
    private var diagnosticsController: MonitorDiagnosticsController?
    private var pairingController: FullHearthPairingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loaded = store.load()
        settings = loaded.settings
        settingsProblem = loaded.problem
        let loadedHistory = historyStore.load()
        ledger = loadedHistory.ledger
        historyProblem = loadedHistory.problem

        fleet.onSnapshot = { [weak self] target, prior, snapshot in
            self?.handleSnapshot(target: target, prior: prior, snapshot: snapshot)
        }
        fleet.onTargetRemoved = { [weak self] id in self?.handleTargetRemoved(id) }
        fullHearthBridge.onUpdate = { [weak self] in self?.refreshRuntimePresentation() }

        configureStatusItem()
        fleet.apply(settings.targets)
        fullHearthBridge.apply(settings.targets)
        refreshRuntimePresentation()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settingsProblem != nil {
                self.openSettings()
            } else if self.settings.targets.isEmpty {
                self.openFirstRunEditor()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fleet.stop()
        fullHearthBridge.stop()
    }

    private func configureStatusItem() {
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()
    }

    private func refreshRuntimePresentation() {
        updateStatusButton()
        if !menuIsOpen { rebuildMenu() }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        let tint: NSColor?
        if settingsProblem != nil {
            symbol = "exclamationmark.triangle.fill"
            description = "Hearth Monitor settings need attention"
            tint = .systemOrange
        } else {
            switch fleet.overallPhase {
            case .healthy:
                symbol = "checkmark.circle.fill"
                description = "Hearth Monitor: all runners healthy"
                tint = .systemGreen
            case .busy:
                symbol = "hourglass.circle.fill"
                description = "Hearth Monitor: a runner is busy"
                tint = .systemBlue
            case .down:
                symbol = "exclamationmark.circle.fill"
                description = "Hearth Monitor: a runner is down"
                tint = .systemRed
            case .checking:
                symbol = "circle.dotted"
                description = "Hearth Monitor: checking runners"
                tint = .systemOrange
            case nil:
                symbol = "waveform.path.ecg.rectangle"
                description = "Hearth Monitor: no runner configured"
                tint = nil
            }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.contentTintColor = tint
        button.toolTip = description
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let heading = NSMenuItem(title: overallMenuTitle, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        if let settingsProblem {
            addWarning("Settings need attention", detail: settingsProblem)
        }
        if let historyProblem {
            addWarning("History needs attention", detail: historyProblem)
        }

        if settings.targets.isEmpty {
            let empty = NSMenuItem(title: "No runner configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            for target in settings.targets { menu.addItem(targetMenuItem(target)) }
            menu.addItem(.separator())
            addAction("Check All Now", #selector(checkAllTapped), keyEquivalent: "r")
            addAction("Open Details…", #selector(detailsTapped), keyEquivalent: "d")
        }

        menu.addItem(.separator())
        addAlertsMenu()
        addLoginItemMenu()
        addAction("Incident History…", #selector(historyTapped), keyEquivalent: "h")
        addAction("Add Runner…", #selector(addRunnerTapped))
        addAction("Settings…", #selector(settingsTapped), keyEquivalent: ",")
        addAction("Hearth Monitor Help…", #selector(helpTapped))
        addAction("Privacy Policy…", #selector(privacyTapped))
        menu.addItem(.separator())
        addAction("Quit Hearth Monitor", #selector(quitTapped), keyEquivalent: "q")
    }

    private var overallMenuTitle: String {
        guard !settings.targets.isEmpty else { return "Hearth Monitor" }
        let snapshots = settings.targets.compactMap { fleet.snapshots[$0.id] }
        let down = snapshots.filter { $0.phase == .down }.count
        if down > 0 { return "Hearth Monitor: \(down) down" }
        if snapshots.contains(where: { $0.phase == .checking }) { return "Hearth Monitor: checking" }
        if snapshots.contains(where: { $0.phase == .busy }) { return "Hearth Monitor: serving" }
        return "Hearth Monitor: all healthy"
    }

    private func targetMenuItem(_ target: MonitorTarget) -> NSMenuItem {
        let snapshot = fleet.snapshots[target.id] ?? MonitorSnapshot(
            targetID: target.id,
            now: Date(),
            deepProbeConfigured: target.normalizedProbeModel != nil)
        let item = NSMenuItem(
            title: "\(target.name): \(MonitorPresentation.title(snapshot))",
            action: nil,
            keyEquivalent: "")
        item.image = NSImage(
            systemSymbolName: MonitorPresentation.symbol(snapshot),
            accessibilityDescription: MonitorPresentation.title(snapshot))
        item.toolTip = MonitorPresentation.detail(snapshot)

        let submenu = NSMenu(title: target.name)
        let status = NSMenuItem(
            title: MonitorPresentation.detail(snapshot),
            action: nil,
            keyEquivalent: "")
        status.isEnabled = false
        submenu.addItem(status)
        let checked = NSMenuItem(
            title: "Checked \(MonitorPresentation.relative(snapshot.checkedAt))",
            action: nil,
            keyEquivalent: "")
        checked.isEnabled = false
        submenu.addItem(checked)
        if !snapshot.residentModels.isEmpty {
            let names = snapshot.residentModels.prefix(3).map(\.name).joined(separator: ", ")
            let suffix = snapshot.residentModels.count > 3 ? " +\(snapshot.residentModels.count - 3)" : ""
            let models = NSMenuItem(
                title: "Resident: \(names)\(suffix)",
                action: nil,
                keyEquivalent: "")
            models.isEnabled = false
            submenu.addItem(models)
        }
        if target.normalizedProbeModel != nil {
            let deep = NSMenuItem(
                title: deepProbeMenuText(snapshot),
                action: nil,
                keyEquivalent: "")
            deep.isEnabled = false
            submenu.addItem(deep)
        }
        if target.fullHearth != nil {
            let bridge = NSMenuItem(
                title: fullHearthMenuText(targetID: target.id),
                action: nil,
                keyEquivalent: "")
            bridge.isEnabled = false
            submenu.addItem(bridge)
        }
        submenu.addItem(.separator())
        let check = NSMenuItem(title: "Check Now", action: #selector(checkTargetTapped(_:)), keyEquivalent: "")
        check.target = self
        check.representedObject = target.id.uuidString
        check.isEnabled = !fleet.checkingTargetIDs.contains(target.id)
        submenu.addItem(check)
        let details = NSMenuItem(title: "Open Details…", action: #selector(targetDetailsTapped(_:)), keyEquivalent: "")
        details.target = self
        details.representedObject = target.id.uuidString
        submenu.addItem(details)
        let pairing = NSMenuItem(
            title: target.fullHearth == nil ? "Connect Full Hearth…" : "Full Hearth Connection…",
            action: #selector(fullHearthConnectionTapped(_:)),
            keyEquivalent: "")
        pairing.target = self
        pairing.representedObject = target.id.uuidString
        submenu.addItem(pairing)
        item.submenu = submenu
        return item
    }

    private func deepProbeMenuText(_ snapshot: MonitorSnapshot) -> String {
        switch snapshot.deepProbeLastSucceeded {
        case true: return "Inference check passed \(MonitorPresentation.relative(snapshot.deepProbeLastAt))"
        case false: return "Inference check failed \(MonitorPresentation.relative(snapshot.deepProbeLastAt))"
        case nil: return "Inference check waiting for first run"
        }
    }

    private func fullHearthMenuText(targetID: UUID) -> String {
        guard let snapshot = fullHearthBridge.snapshots[targetID] else {
            return "Full Hearth: checking recovery status"
        }
        switch snapshot.phase {
        case .connected where snapshot.hasManagedRecovery:
            return "Full Hearth: managed recovery active"
        case .connected:
            return "Full Hearth: connected, recovery not managed"
        case .checking: return "Full Hearth: checking"
        case .unauthorized: return "Full Hearth: token rejected"
        case .credentialMissing: return "Full Hearth: token missing"
        case .runnerMismatch: return "Full Hearth: runner mismatch"
        case .unavailable: return "Full Hearth: unavailable"
        }
    }

    private func addAlertsMenu() {
        if !settings.alertsEnabled {
            addAction("Enable Outage Alerts…", #selector(toggleAlertsTapped))
            return
        }
        let enabled = NSMenuItem(
            title: "Outage Alerts Enabled",
            action: #selector(toggleAlertsTapped),
            keyEquivalent: "")
        enabled.target = self
        enabled.state = .on
        enabled.toolTip = "Turn off outage and recovery notifications. Monitoring and history continue."
        menu.addItem(enabled)

        let snooze = NSMenuItem(title: "Snooze Alerts", action: nil, keyEquivalent: "")
        let snoozeMenu = NSMenu(title: "Snooze Alerts")
        if let until = settings.alertsSnoozedUntil, until > Date() {
            let current = NSMenuItem(
                title: "Snoozed until \(until.formatted(date: .omitted, time: .shortened))",
                action: nil,
                keyEquivalent: "")
            current.isEnabled = false
            snoozeMenu.addItem(current)
            let resume = NSMenuItem(title: "Resume Now", action: #selector(resumeAlertsTapped), keyEquivalent: "")
            resume.target = self
            snoozeMenu.addItem(resume)
            snoozeMenu.addItem(.separator())
        }
        for option in [("30 Minutes", 1_800), ("1 Hour", 3_600), ("4 Hours", 14_400)] {
            let item = NSMenuItem(title: option.0, action: #selector(snoozeAlertsTapped(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.1
            snoozeMenu.addItem(item)
        }
        let tomorrow = NSMenuItem(
            title: "Until \(tomorrowAtEight().formatted(date: .abbreviated, time: .shortened))",
            action: #selector(snoozeAlertsTapped(_:)),
            keyEquivalent: "")
        tomorrow.target = self
        tomorrow.tag = -1
        snoozeMenu.addItem(tomorrow)
        snooze.submenu = snoozeMenu
        menu.addItem(snooze)
    }

    private func addLoginItemMenu() {
        let state = MonitorLoginItem.state
        let title: String
        switch state {
        case .off, .on: title = "Open at Login"
        case .requiresApproval: title = "Open at Login: Approval Required"
        case .unavailable: title = "Open at Login: Install in Applications"
        }
        let item = NSMenuItem(title: title, action: #selector(toggleLoginItemTapped), keyEquivalent: "")
        item.target = self
        item.state = state == .on ? .on : .off
        item.isEnabled = state != .unavailable
        menu.addItem(item)
    }

    private func addWarning(_ title: String, detail: String) {
        let warning = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        warning.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: title)
        warning.isEnabled = false
        warning.toolTip = detail
        menu.addItem(warning)
    }

    private func addAction(_ title: String,
                           _ action: Selector,
                           keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private func handleSnapshot(target: MonitorTarget,
                                prior: MonitorSnapshot?,
                                snapshot: MonitorSnapshot) {
        let event = ledger.observe(target: target, snapshot: snapshot)
        if event != .none { persistHistory() }
        historyController?.update(ledger: ledger, problem: historyProblem)
        refreshRuntimePresentation()
        Task { [weak self] in await self?.deliverAlerts(for: event) }
    }

    private func handleTargetRemoved(_ id: UUID) {
        let event = ledger.stopMonitoring(targetID: id)
        if event != .none { persistHistory() }
        historyController?.update(ledger: ledger, problem: historyProblem)
    }

    private func persistHistory() {
        guard historyProblem == nil else { return }
        do {
            try historyStore.save(ledger)
        } catch {
            historyProblem = "Incident history could not be saved: \(error.localizedDescription)"
        }
        historyController?.update(ledger: ledger, problem: historyProblem)
    }

    private func deliverAlerts(for event: MonitorIncidentEvent) async {
        let now = Date()
        if let until = settings.alertsSnoozedUntil, until <= now {
            var updated = settings
            updated.alertsSnoozedUntil = nil
            try? saveGlobalSettings(updated)
        }
        guard settings.alertsEnabled,
              settings.alertsSnoozedUntil.map({ $0 <= now }) ?? true else { return }

        let pendingOutages = MonitorAlertPolicy.pendingOutages(
            in: ledger,
            monitoredTargetIDs: Set(settings.targets.map(\.id)),
            alertsEnabled: settings.alertsEnabled,
            snoozedUntil: settings.alertsSnoozedUntil,
            now: now)
        for incident in pendingOutages {
            await deliverOutage(incident, now: now)
        }

        for incident in MonitorAlertPolicy.pendingRecoveries(
            in: ledger,
            alertsEnabled: settings.alertsEnabled,
            snoozedUntil: settings.alertsSnoozedUntil,
            now: now) {
            await deliverRecovery(incident, now: now)
        }
    }

    private func deliverOutage(_ incident: MonitorIncident, now: Date) async {
        let key = "\(incident.id)-outage"
        guard alertRetryAfter[key].map({ $0 <= now }) ?? true,
              alertsInFlight.insert(key).inserted else { return }
        defer { alertsInFlight.remove(key) }
        let delivered = await notifier.deliver(
            MonitorAlertContent.outage(incident),
            incidentID: incident.id,
            targetID: incident.targetID,
            kind: "outage")
        if delivered {
            alertRetryAfter[key] = nil
            if ledger.markOutageAlerted(id: incident.id, at: now) { persistHistory() }
        } else {
            alertRetryAfter[key] = now.addingTimeInterval(300)
        }
    }

    private func deliverRecovery(_ incident: MonitorIncident, now: Date) async {
        let key = "\(incident.id)-recovery"
        guard alertRetryAfter[key].map({ $0 <= now }) ?? true,
              alertsInFlight.insert(key).inserted else { return }
        defer { alertsInFlight.remove(key) }
        let delivered = await notifier.deliver(
            MonitorAlertContent.recovery(incident),
            incidentID: incident.id,
            targetID: incident.targetID,
            kind: "recovery")
        if delivered {
            alertRetryAfter[key] = nil
            if ledger.markRecoveryAlerted(id: incident.id, at: now) { persistHistory() }
        } else {
            alertRetryAfter[key] = now.addingTimeInterval(300)
        }
    }

    private func openFirstRunEditor() {
        editor = MonitorTargetEditorController(
            target: MonitorTarget(),
            http: http,
            onSave: { [weak self] target in try self?.save(target) },
            onClose: { [weak self] in self?.editor = nil })
        editor?.show(title: "Welcome to Hearth Monitor", discoverOnOpen: true)
    }

    private func openSettings() {
        if preferences == nil {
            preferences = MonitorPreferencesController(
                settings: settings,
                problem: settingsProblem,
                http: http,
                notifier: notifier,
                onChange: { [weak self] updated in try self?.save(updated) })
        }
        preferences?.show(settings: settings, problem: settingsProblem)
    }

    private func openHistory() {
        if historyController == nil {
            historyController = MonitorHistoryController(
                ledger: ledger,
                problem: historyProblem,
                onClearResolved: { [weak self] in self?.clearResolvedHistory() },
                onReset: { [weak self] in self?.resetHistory() })
        }
        historyController?.update(ledger: ledger, problem: historyProblem)
        historyController?.show()
    }

    private func openDiagnostics(selectedID: UUID?) {
        if diagnosticsController == nil {
            diagnosticsController = MonitorDiagnosticsController(
                fleet: fleet,
                fullHearthBridge: fullHearthBridge,
                onConnectFullHearth: { [weak self] id in self?.openFullHearthConnection(targetID: id) },
                onOpenSettings: { [weak self] in self?.openSettings() })
        }
        diagnosticsController?.show(selectedID: selectedID)
    }

    private func clearResolvedHistory() {
        guard historyProblem == nil else { return }
        ledger.clearClosed()
        persistHistory()
        historyController?.update(ledger: ledger, problem: historyProblem)
    }

    private func resetHistory() {
        let empty = MonitorIncidentLedger()
        do {
            try historyStore.save(empty)
            ledger = empty
            historyProblem = nil
        } catch {
            historyProblem = "Incident history could not be reset: \(error.localizedDescription)"
        }
        historyController?.update(ledger: ledger, problem: historyProblem)
        refreshRuntimePresentation()
    }

    private func save(_ target: MonitorTarget) throws {
        var updated = settings
        updated.upsert(target)
        try save(updated)
    }

    private func save(_ updated: MonitorSettings) throws {
        let updatedIDs = Set(updated.targets.map(\.id))
        let removedPairedIDs = settings.targets
            .filter { $0.fullHearth != nil && !updatedIDs.contains($0.id) }
            .map(\.id)
        var tokenBackups: [UUID: String] = [:]
        do {
            for id in removedPairedIDs {
                if let token = try secrets.token(for: id) { tokenBackups[id] = token }
                try secrets.deleteToken(for: id)
            }
            try store.save(updated)
        } catch {
            for (id, token) in tokenBackups { try? secrets.setToken(token, for: id) }
            throw error
        }
        settings = updated
        settingsProblem = nil
        fleet.apply(updated.targets)
        fullHearthBridge.apply(updated.targets)
        preferences?.settingsDidChange(updated)
        refreshRuntimePresentation()
        if updated.alertsEnabled {
            Task { [weak self] in await self?.deliverAlerts(for: .none) }
        }
    }

    private func saveGlobalSettings(_ updated: MonitorSettings) throws {
        try store.save(updated)
        settings = updated
        settingsProblem = nil
        preferences?.settingsDidChange(updated)
        refreshRuntimePresentation()
    }

    private func openFullHearthConnection(targetID: UUID) {
        guard let target = settings.targets.first(where: { $0.id == targetID }) else { return }
        let token: String
        do {
            token = try secrets.token(for: targetID) ?? ""
        } catch {
            presentMessage(title: "Keychain token unavailable", text: error.localizedDescription)
            return
        }
        pairingController = FullHearthPairingController(
            target: target,
            token: token,
            client: fullHearthClient,
            onSave: { [weak self] endpoint, token in
                try self?.saveFullHearthConnection(
                    targetID: targetID,
                    endpoint: endpoint,
                    token: token)
            },
            onDisconnect: { [weak self] in
                try self?.disconnectFullHearth(targetID: targetID)
            },
            onClose: { [weak self] in self?.pairingController = nil })
        pairingController?.show()
    }

    private func saveFullHearthConnection(targetID: UUID,
                                          endpoint: FullHearthEndpoint,
                                          token: String) throws {
        guard let index = settings.targets.firstIndex(where: { $0.id == targetID }) else { return }
        let previous = try secrets.token(for: targetID)
        try secrets.setToken(token, for: targetID)
        var updated = settings
        updated.targets[index].fullHearth = endpoint
        do {
            try save(updated)
        } catch {
            if let previous { try? secrets.setToken(previous, for: targetID) }
            else { try? secrets.deleteToken(for: targetID) }
            throw error
        }
        Task { [weak self] in await self?.fullHearthBridge.refresh(targetID: targetID) }
    }

    private func disconnectFullHearth(targetID: UUID) throws {
        guard let index = settings.targets.firstIndex(where: { $0.id == targetID }) else { return }
        let previous = try secrets.token(for: targetID)
        try secrets.deleteToken(for: targetID)
        var updated = settings
        updated.targets[index].fullHearth = nil
        do {
            try save(updated)
        } catch {
            if let previous { try? secrets.setToken(previous, for: targetID) }
            throw error
        }
    }

    private func tomorrowAtEight(from now: Date = Date()) -> Date {
        MonitorSnoozeSchedule.tomorrowMorning(from: now)
    }

    private func presentMessage(title: String, text: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        MonitorWindowActivation.restoreAccessoryWhenAppropriate()
    }

    @objc private func addRunnerTapped() {
        editor = MonitorTargetEditorController(
            target: MonitorTarget(),
            http: http,
            onSave: { [weak self] target in try self?.save(target) },
            onClose: { [weak self] in self?.editor = nil })
        editor?.show(title: "Add Runner", discoverOnOpen: true)
    }

    @objc func settingsTapped() { openSettings() }
    @objc private func historyTapped() { openHistory() }
    @objc private func detailsTapped() { openDiagnostics(selectedID: settings.selectedTargetID) }
    @objc private func checkAllTapped() { fleet.checkAllNow() }

    @objc private func checkTargetTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        Task { [weak self] in await self?.fleet.checkNow(targetID: id) }
    }

    @objc private func targetDetailsTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        openDiagnostics(selectedID: id)
    }

    @objc private func fullHearthConnectionTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        openFullHearthConnection(targetID: id)
    }

    @objc private func toggleAlertsTapped() {
        if settings.alertsEnabled {
            var updated = settings
            updated.alertsEnabled = false
            updated.alertsSnoozedUntil = nil
            do { try saveGlobalSettings(updated) }
            catch { presentMessage(title: "Alerts were not changed", text: error.localizedDescription) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let permission = await self.notifier.requestPermission()
            guard permission == .enabled else {
                self.presentMessage(
                    title: "Notifications are not allowed",
                    text: "Allow Hearth Monitor in System Settings → Notifications, then try again. Health checks and history continue without alerts.")
                return
            }
            var updated = self.settings
            updated.alertsEnabled = true
            do {
                try self.saveGlobalSettings(updated)
                await self.deliverAlerts(for: .none)
            } catch {
                self.presentMessage(title: "Alerts could not be enabled", text: error.localizedDescription)
            }
        }
    }

    @objc private func snoozeAlertsTapped(_ sender: NSMenuItem) {
        var updated = settings
        updated.alertsSnoozedUntil = sender.tag == -1
            ? tomorrowAtEight()
            : Date().addingTimeInterval(TimeInterval(sender.tag))
        do { try saveGlobalSettings(updated) }
        catch { presentMessage(title: "Alerts were not snoozed", text: error.localizedDescription) }
    }

    @objc private func resumeAlertsTapped() {
        var updated = settings
        updated.alertsSnoozedUntil = nil
        do {
            try saveGlobalSettings(updated)
            Task { [weak self] in await self?.deliverAlerts(for: .none) }
        } catch {
            presentMessage(title: "Alerts were not resumed", text: error.localizedDescription)
        }
    }

    @objc private func toggleLoginItemTapped() {
        do {
            try MonitorLoginItem.setEnabled(MonitorLoginItem.state != .on)
            if MonitorLoginItem.state == .requiresApproval {
                presentMessage(
                    title: "Approval required",
                    text: "Allow Hearth Monitor in System Settings → General → Login Items.")
            }
            refreshRuntimePresentation()
        } catch {
            presentMessage(title: "Start at Login was not changed", text: error.localizedDescription)
        }
    }

    @objc private func quitTapped() { NSApp.terminate(nil) }

    @objc private func helpTapped() {
        openWebPage(
            "https://github.com/adamskijow/Hearth/blob/main/docs/hearth-monitor.md",
            failureTitle: "Help could not be opened")
    }

    @objc private func privacyTapped() {
        openWebPage(
            "https://github.com/adamskijow/Hearth/blob/main/PRIVACY.md",
            failureTitle: "Privacy policy could not be opened")
    }

    private func openWebPage(_ address: String, failureTitle: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            presentMessage(
                title: failureTitle,
                text: "Visit github.com/adamskijow/Hearth for documentation and support.")
            return
        }
    }
}

extension MonitorAppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        rebuildMenu()
    }
}
