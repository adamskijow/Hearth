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
    private var runner: OllamaRunner!
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var latestState = SupervisorState()
    private var recentEvents: [String] = []
    private var configNote: String?
    private var binaryMissingPath: String?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let loaded = ConfigStore.load()
        let config = loaded.config
        configNote = loaded.note

        if !FileManager.default.fileExists(atPath: config.ollamaBinaryPath) {
            binaryMissingPath = config.ollamaBinaryPath
        }

        runner = config.makeOllamaRunner()
        engine = SupervisorEngine(
            clock: SystemClock(),
            processes: FoundationProcessController(logFileURL: AppPaths.runnerLogFile),
            http: URLSessionHTTPClient(),
            runner: runner,
            power: IOKitPowerManager(),
            notifier: makeNotifier(config: config),
            policy: config.policy()
        )

        LocalNotifier.requestAuthorization()

        // Autostart at login. A no op (reflected honestly in the menu) when run
        // unbundled, for example via `swift run`.
        if LoginItem.isAvailable && !LoginItem.isRegistered {
            LoginItem.register()
        }

        configureStatusItem()
        installSignalHandlers()
        subscribeToState()
        subscribeToEvents()

        Task {
            await engine.start()
            await engine.runLoop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best effort: release the power assertion and kill the child on quit.
        // Detached so it runs off the main actor while we briefly block here.
        guard let engine else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await engine.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Wiring

    private func makeNotifier(config: HearthConfig) -> Notifier {
        var notifiers: [Notifier] = []
        if config.localNotifications {
            notifiers.append(LocalNotifier())
        }
        if let topic = config.ntfyTopic, !topic.trimmingCharacters(in: .whitespaces).isEmpty {
            notifiers.append(NtfyNotifier(server: config.ntfyServer, topic: topic))
        }
        return CompositeNotifier(notifiers)
    }

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
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func subscribeToState() {
        let states = engine.states
        Task { [weak self] in
            for await state in states {
                self?.latestState = state
                self?.updateStatusButton()
            }
        }
    }

    private func subscribeToEvents() {
        let events = engine.events
        Task { [weak self] in
            for await event in events {
                self?.appendRecentEvent(event)
            }
        }
    }

    private func appendRecentEvent(_ event: SupervisorEvent) {
        recentEvents.append(MenuFormat.describe(event))
        if recentEvents.count > 12 {
            recentEvents.removeFirst(recentEvents.count - 12)
        }
    }

    // MARK: - Status button

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let phase = latestState.phase
        let symbol = MenuFormat.symbolName(for: phase)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hearth: \(phase.rawValue)")
        button.image?.isTemplate = (MenuFormat.tint(for: phase) == nil)
        button.contentTintColor = MenuFormat.tint(for: phase)
    }

    // MARK: - Menu (rebuilt each time it opens, so uptime is live)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled("Hearth: supervising \(runner.name)"))
        menu.addItem(disabled(MenuFormat.statusLine(latestState, now: Date())))

        if let uptime = latestState.uptime(asOf: Date()) {
            menu.addItem(disabled("Uptime: \(MenuFormat.duration(uptime))"))
        }
        if let reason = latestState.lastRestartReason {
            menu.addItem(disabled("Last restart: \(reason)"))
        }
        if latestState.restartCount > 0 {
            menu.addItem(disabled("Restarts: \(latestState.restartCount)"))
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Resident models"))
        if latestState.residentModels.isEmpty {
            menu.addItem(disabled("   none"))
        } else {
            for model in latestState.residentModels {
                menu.addItem(disabled("   \(MenuFormat.model(model))"))
            }
        }

        if let path = binaryMissingPath {
            menu.addItem(.separator())
            menu.addItem(disabled("\u{26A0} Ollama binary not found at \(path)"))
        }
        if let note = configNote {
            menu.addItem(.separator())
            menu.addItem(disabled(note))
        }

        menu.addItem(.separator())
        addAction("Start", #selector(startTapped), enabled: latestState.phase == .stopped)
        addAction("Restart", #selector(restartTapped), enabled: latestState.phase != .stopped)
        addAction("Stop", #selector(stopTapped), enabled: latestState.phase != .stopped)
        addAction("Open Logs", #selector(openLogsTapped), enabled: true)
        addAction("Reveal Config in Finder", #selector(revealConfigTapped), enabled: true)

        if !recentEvents.isEmpty {
            let activity = NSMenu()
            for line in recentEvents.reversed() {
                activity.addItem(disabled(line))
            }
            let item = NSMenuItem(title: "Recent activity", action: nil, keyEquivalent: "")
            item.submenu = activity
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItemTapped), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isRegistered ? .on : .off
        login.isEnabled = LoginItem.isAvailable
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

    private func addAction(_ title: String, _ selector: Selector, enabled: Bool, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func startTapped() {
        Task {
            await engine.start()
            await engine.runLoop()
        }
    }

    @objc private func stopTapped() {
        Task { await engine.stop() }
    }

    @objc private func restartTapped() {
        Task { await engine.restart() }
    }

    @objc private func openLogsTapped() {
        let logFile = AppPaths.runnerLogFile
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.open(logFile)
        } else {
            NSWorkspace.shared.open(AppPaths.logDirectory)
        }
    }

    @objc private func revealConfigTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configFile])
    }

    @objc private func toggleLoginItemTapped() {
        if LoginItem.isRegistered {
            LoginItem.unregister()
        } else {
            LoginItem.register()
        }
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }
}
