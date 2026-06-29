// SPDX-License-Identifier: MIT

import AppKit
import SupervisorCore

/// The deployable agent. It loads config, constructs the engine with real I/O,
/// drives the menubar from the published `SupervisorState`, and routes user
/// actions back to the engine. It does no supervision logic itself; that all
/// lives in SupervisorCore.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: SupervisorEngine!
    private var coordinator: SupervisionCoordinator!
    private var runner: (any Runner)!
    private var controlServer: ControlServer?
    private var pressureMonitor: PressureMonitor?
    private var processController: FoundationProcessController!
    private var metricsProvider: SystemMetricsProvider!
    private var config = HearthConfig()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var preferences: PreferencesController?

    private var latestState = SupervisorState()
    private var configNote: String?
    private var configProblem = false
    private var configDiagnostics: [Diagnostic] = []
    private var binaryMissingPath: String?
    private var suggestedBinaryPath: String?
    private var signalSources: [DispatchSourceSignal] = []
    private var stateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// Bumped on each config reload so a reload that started later can supersede
    /// one still awaiting the old engine's teardown, rather than both rebuilding.
    private var reloadGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LocalNotifier.requestAuthorization()
        // Recover from a previous hard crash: sweep any leaked runner group before
        // we start a new one.
        if let swept = RunnerStateStore.sweepOrphan() {
            LocalNotifier.post(title: "Hearth recovered a leaked runner", body: swept)
        }
        configureStatusItem()
        installSignalHandlers()
        Task { await reloadFromDisk(firstRun: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        pressureMonitor?.stop()
        guard let coordinator else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await coordinator.end()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        // Ensure a wedged child is dead before we exit, rather than relying on the
        // engine's deferred SIGKILL which exit would outrun.
        RunnerStateStore.killRecordedGroupNow()
    }

    // MARK: - Config load and live reload

    /// Re-read the config from disk and apply it. A parse failure while already
    /// running keeps the current working setup rather than reverting everything;
    /// the problem is surfaced loudly instead.
    func reloadFromDisk(firstRun: Bool) async {
        let loaded = ConfigStore.load()
        if loaded.isProblem, engine != nil {
            configNote = loaded.note
            configProblem = true
            updateStatusButton()
            LocalNotifier.post(title: "Hearth: config not applied", body: loaded.note ?? "The config could not be read.")
            return
        }
        await applyConfig(loaded)
        if firstRun {
            firstRunGuidance(loaded)
        }
    }

    /// Tear down the current engine and rebuild it from a config. Safe to call on
    /// first launch (nothing to tear down) and on every later reload.
    private func applyConfig(_ loaded: ConfigLoad) async {
        reloadGeneration &+= 1
        let generation = reloadGeneration

        controlServer?.stop()
        pressureMonitor?.stop()
        stateTask?.cancel()
        eventTask?.cancel()
        if let coordinator { await coordinator.end() }

        // Several triggers (SIGHUP, the menu, a Preferences save) each kick off a
        // reload Task; they interleave at the await above. If a newer reload
        // started while this one waited for the old engine to stop, let it win,
        // rather than building a second engine and control server and spawning a
        // second runner.
        guard generation == reloadGeneration else { return }

        config = loaded.config
        configNote = loaded.note
        configProblem = loaded.isProblem
        configDiagnostics = ConfigDiagnostics.check(loaded.config)
        binaryMissingPath = nil
        suggestedBinaryPath = nil
        if config.isManaged, !FileManager.default.isExecutableFile(atPath: config.selectedBinaryPath) {
            binaryMissingPath = config.selectedBinaryPath
            suggestedBinaryPath = RunnerLocator.locate(config.runner)
        }

        let assembly = SupervisorAssembly.make(config: config, includeLocalNotifications: true)
        processController = assembly.processController
        metricsProvider = assembly.metricsProvider
        runner = assembly.runner
        engine = assembly.engine
        coordinator = assembly.coordinator
        controlServer = assembly.controlServer
        controlServer?.start()
        pressureMonitor = assembly.pressureMonitor
        pressureMonitor?.start()

        if LoginItem.isAvailable && !LoginItem.isRegistered {
            LoginItem.register()
        }

        subscribeToState()
        subscribeToEvents()
        updateStatusButton()
        await coordinator.begin()
    }

    private func firstRunGuidance(_ loaded: ConfigLoad) {
        if let missing = binaryMissingPath {
            let suffix = suggestedBinaryPath.map { " Found one at \($0) (open Preferences to use it)." } ?? " Set the runner binary in Preferences."
            LocalNotifier.post(title: "Hearth: runner not found", body: "\(runner.name) is not at \(missing).\(suffix)")
        } else if loaded.createdDefault {
            LocalNotifier.post(title: "Hearth is running", body: "Supervising \(runner.name). Open Preferences from the menubar to customize.")
        }
    }

    // MARK: - Wiring

    private func configureStatusItem() {
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()
    }

    /// A headless agent is often stopped with `kill` or by launchd, which send
    /// SIGTERM (and SIGINT from a terminal). AppKit does not route those through
    /// applicationWillTerminate by default, so the child would be orphaned and the
    /// power assertion would only drop because the process died. Catch them and
    /// terminate cleanly, which runs stop(): kill the child, release power.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        // SIGHUP reloads the config, the usual daemon convention.
        signal(SIGHUP, SIG_IGN)
        let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup.setEventHandler { [weak self] in
            Task { await self?.reloadFromDisk(firstRun: false) }
        }
        hup.resume()
        signalSources.append(hup)
    }

    private func subscribeToState() {
        let states = engine.states
        stateTask = Task { [weak self] in
            for await state in states {
                if Task.isCancelled { return }
                self?.latestState = state
                self?.updateStatusButton()
            }
        }
    }

    private func subscribeToEvents() {
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { return }
                self?.appendRecentEvent(event)
            }
        }
    }

    private func appendRecentEvent(_ event: SupervisorEvent) {
        // Persist to disk so the recent-activity history survives a restart; the
        // menu reads it back rather than keeping an in-memory list.
        EventLogStore.append(event)
    }

    // MARK: - Status button

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let phase = latestState.phase
        let needsAttention = configProblem || binaryMissingPath != nil
            || configDiagnostics.contains { $0.severity == .error }
        let symbol = needsAttention ? "exclamationmark.triangle.fill" : MenuFormat.symbolName(for: phase)
        let label = "Hearth: \(phase.rawValue)"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "flame", accessibilityDescription: label)
        let tint = needsAttention ? NSColor.systemYellow : MenuFormat.tint(for: phase)
        button.image?.isTemplate = (tint == nil)
        button.contentTintColor = tint
    }

    // MARK: - Menu (rebuilt each time it opens, so uptime is live)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let now = Date()

        // Setup problems first, prominent, with one-click fixes where possible.
        if let path = binaryMissingPath {
            menu.addItem(infoRow(headlineAttr("\u{26A0} \(runner.name) binary not found", color: .systemYellow)))
            menu.addItem(infoRow(detailAttr("   \(path)")))
            if let suggested = suggestedBinaryPath {
                addAction("Use detected: \(suggested)", #selector(useDetectedBinaryTapped), enabled: true)
            }
            addAction("Open Preferences\u{2026}", #selector(openPreferencesTapped), enabled: true)
            menu.addItem(.separator())
        }
        if configProblem, let note = configNote {
            menu.addItem(infoRow(headlineAttr("\u{26A0} Config problem", color: .systemYellow)))
            menu.addItem(infoRow(detailAttr("   \(note)")))
            menu.addItem(.separator())
        }
        if !configDiagnostics.isEmpty {
            let errorCount = configDiagnostics.filter { $0.severity == .error }.count
            let color: NSColor = errorCount > 0 ? .systemRed : .systemYellow
            let label = configDiagnostics.count == 1 ? "1 config issue" : "\(configDiagnostics.count) config issues"
            menu.addItem(infoRow(headlineAttr("\u{26A0} \(label)", color: color)))
            for diagnostic in configDiagnostics {
                menu.addItem(infoRow(detailAttr("   \(diagnostic.message)")))
            }
            menu.addItem(.separator())
        }

        // Health: a bright, color-coded headline, then a couple of detail lines.
        let phaseColor = MenuFormat.tint(for: latestState.phase) ?? .labelColor
        menu.addItem(infoRow(headlineAttr(StatusText.headline(latestState, now: now), color: phaseColor)))
        menu.addItem(infoRow(detailAttr(StatusText.contextLine(
            latestState, runnerName: runner.name, managed: config.isManaged, now: now))))
        if latestState.phase != .healthy, let reason = latestState.lastRestartReason {
            menu.addItem(infoRow(detailAttr("Last: \(reason)")))
        }

        let metrics = metricsProvider.sample()
        if let summary = MetricsFormat.summary(metrics) {
            var line = summary
            if let resident = metrics.runnerResidentBytes {
                line += " \u{00B7} Runner \(StatusText.byteString(resident))"
            }
            menu.addItem(infoRow(detailAttr(line)))
        }
        if !latestState.residentModels.isEmpty {
            let loaded = latestState.residentModels.map(StatusText.model).joined(separator: ", ")
            menu.addItem(infoRow(detailAttr("Loaded: \(loaded)")))
        }
        if let url = phoneAccessURL() {
            menu.addItem(phoneAccessItem(url: url))
        }

        menu.addItem(.separator())
        addAction("Start", #selector(startTapped), enabled: latestState.phase == .stopped)
        addAction("Stop", #selector(stopTapped), enabled: latestState.phase != .stopped)
        addAction("Restart", #selector(restartTapped), enabled: latestState.phase != .stopped)
        addAction("Open Logs", #selector(openLogsTapped), enabled: true)
        addAction("Copy Diagnostics", #selector(copyDiagnosticsTapped), enabled: true)

        let recent = EventLogStore.recent(12)
        if !recent.isEmpty {
            let activity = NSMenu()
            for line in recent.reversed() {   // newest first
                activity.addItem(disabled(line))
            }
            let item = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
            item.submenu = activity
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addAction("Preferences\u{2026}", #selector(openPreferencesTapped), enabled: true, keyEquivalent: ",")
        addAction("Reload Config", #selector(reloadConfigTapped), enabled: true)
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItemTapped), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isRegistered ? .on : .off
        login.isEnabled = LoginItem.isAvailable
        if !LoginItem.isAvailable {
            login.toolTip = "Available in the installed, signed app, not when run unbundled."
        }
        menu.addItem(login)

        menu.addItem(.separator())
        addAction("Quit Hearth", #selector(quitTapped), enabled: true, keyEquivalent: "q")
    }

    // MARK: - Menu helpers

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// An information row rendered as a custom view rather than a disabled menu
    /// item. The system greys out disabled items (which read as too dim); a view
    /// shows at full brightness and does not highlight on hover, which is what
    /// non-actionable status text wants.
    private func infoRow(_ attributed: NSAttributedString) -> NSMenuItem {
        let item = NSMenuItem()
        let field = NSTextField(labelWithAttributedString: attributed)
        field.lineBreakMode = .byTruncatingTail
        field.sizeToFit()
        let leftInset: CGFloat = 21, rightInset: CGFloat = 16, height: CGFloat = 19
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: field.frame.width + leftInset + rightInset, height: height))
        field.setFrameOrigin(NSPoint(x: leftInset, y: ((height - field.frame.height) / 2).rounded()))
        container.addSubview(field)
        item.view = container
        return item
    }

    /// The bold, color-coded health line (and warnings).
    private func headlineAttr(_ text: String, color: NSColor) -> NSAttributedString {
        let size = NSFont.menuFont(ofSize: 0).pointSize
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color
        ])
    }

    /// The detail lines under the headline: bright enough to read easily, a step
    /// below the headline in weight and contrast.
    private func detailAttr(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8)
        ])
    }

    private func addAction(_ title: String, _ selector: Selector, enabled: Bool, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: - Phone access

    /// The control URL a phone could actually reach, or nil if the endpoint is off
    /// or only bound to loopback (which a phone cannot use). Prefers the Tailscale
    /// address; an explicit non-loopback configured host is shown as-is.
    private func phoneAccessURL() -> String? {
        guard config.controlEnabled, controlServer != nil else { return nil }
        return PhoneAccess.url(
            tailnetIPv4: NetworkInterfaces.tailnetIPv4(),
            controlHost: config.controlHost,
            controlPort: config.controlPort)
    }

    /// A "Phone Access" submenu: the URL, a scannable QR code, and Copy URL.
    private func phoneAccessItem(url: String) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(infoRow(detailAttr(url)))
        if let qr = QRCode.image(for: url, size: 150) {
            submenu.addItem(qrItem(qr))
        }
        let copy = NSMenuItem(title: "Copy URL", action: #selector(copyPhoneURLTapped), keyEquivalent: "")
        copy.target = self
        submenu.addItem(copy)

        let item = NSMenuItem(title: "Phone Access", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The QR on a white card with a quiet-zone border, so it scans regardless of
    /// the menu's light or dark appearance.
    private func qrItem(_ image: NSImage) -> NSMenuItem {
        let item = NSMenuItem()
        let pad: CGFloat = 12, leftInset: CGFloat = 21
        let side = image.size.width + pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: leftInset + side + 16, height: side))
        let card = NSView(frame: NSRect(x: leftInset, y: 0, width: side, height: side))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 6
        let imageView = NSImageView(frame: NSRect(x: pad, y: pad, width: image.size.width, height: image.size.height))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        card.addSubview(imageView)
        container.addSubview(card)
        item.view = container
        return item
    }

    /// A plain-text snapshot for bug reports: version, runner, status, metrics,
    /// config diagnostics, and recent events, mirroring `hearth doctor`/`status`.
    private func diagnosticsText() -> String {
        let now = Date()
        var lines: [String] = []
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        lines.append("Hearth \(version)")
        lines.append("Runner: \(config.runner) (\(config.isManaged ? "managed" : "attached")) at \(config.host):\(config.port)")
        lines.append("Status: \(StatusText.headline(latestState, now: now))")
        lines.append(StatusText.contextLine(latestState, runnerName: runner.name, managed: config.isManaged, now: now))
        let metrics = metricsProvider.sample()
        if let summary = MetricsFormat.summary(metrics) {
            var line = summary
            if let resident = metrics.runnerResidentBytes {
                line += " \u{00B7} Runner \(StatusText.byteString(resident))"
            }
            lines.append(line)
        }
        if !latestState.residentModels.isEmpty {
            lines.append("Loaded: \(latestState.residentModels.map(StatusText.model).joined(separator: ", "))")
        }
        let diagnostics = ConfigDiagnostics.check(config)
        if !diagnostics.isEmpty {
            lines.append("Config issues:")
            for diagnostic in diagnostics {
                lines.append("  [\(diagnostic.severity.rawValue)] \(diagnostic.message)")
            }
        }
        let recent = EventLogStore.recent(10)
        if !recent.isEmpty {
            lines.append("Recent events:")
            for line in recent { lines.append("  \(line)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    @objc private func startTapped() { Task { await coordinator.begin() } }
    @objc private func stopTapped() { Task { await coordinator.end() } }
    @objc private func restartTapped() { Task { await coordinator.restart() } }

    @objc private func reloadConfigTapped() {
        Task { await reloadFromDisk(firstRun: false) }
    }

    @objc private func useDetectedBinaryTapped() {
        guard let detected = suggestedBinaryPath else { return }
        var updated = config
        switch updated.runner.lowercased() {
        case "lmstudio", "lm-studio", "lm_studio": updated.lmStudioBinaryPath = detected
        case "mlx", "mlx_lm", "mlx-lm": updated.mlxBinaryPath = detected
        default: updated.ollamaBinaryPath = detected
        }
        ConfigStore.save(updated)
        Task { await reloadFromDisk(firstRun: false) }
    }

    @objc private func openPreferencesTapped() {
        if preferences == nil {
            preferences = PreferencesController(config: config) { [weak self] newConfig in
                ConfigStore.save(newConfig)
                Task { await self?.reloadFromDisk(firstRun: false) }
            }
        }
        preferences?.show(config: config)
    }

    @objc private func openLogsTapped() {
        let logFile = AppPaths.runnerLogFile
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.open(logFile)
        } else {
            NSWorkspace.shared.open(AppPaths.logDirectory)
        }
    }

    @objc private func copyPhoneURLTapped() {
        guard let url = phoneAccessURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func copyDiagnosticsTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText(), forType: .string)
    }

    @objc private func toggleLoginItemTapped() {
        if LoginItem.isRegistered { LoginItem.unregister() } else { LoginItem.register() }
    }

    @objc private func quitTapped() { NSApp.terminate(nil) }
}
