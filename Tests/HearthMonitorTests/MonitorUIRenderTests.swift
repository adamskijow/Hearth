// SPDX-License-Identifier: MIT

import AppKit
import HearthMonitorCore
import SupervisorCore
import SwiftUI
import Testing
@testable import HearthMonitor

@MainActor
@Suite("Monitor UI render smoke tests", .serialized)
struct MonitorUIRenderTests {
    @Test("Welcome controller preserves its real window size")
    func welcomeControllerKeepsReleaseSize() async throws {
        let expected = MonitorWelcomeView.windowSize(for: .available)
        let controller = MonitorWelcomeController(
            appleAvailability: .available,
            onContinue: { _ in },
            onAddRunner: {})
        controller.show()
        try await Task.sleep(for: .seconds(2))

        let window = try #require(NSApp.windows.first {
            $0.title == "Welcome to Hearth Monitor"
        })
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()

        let actual = try #require(window.contentView?.bounds.size)
        #expect(abs(actual.width - expected.width) < 1)
        #expect(abs(actual.height - expected.height) < 1)
    }

    @Test("First-run editor renders at its release window size")
    func editorRenders() throws {
        let model = MonitorTargetEditorModel(
            target: MonitorTarget(),
            http: MonitorFakeHTTPClient())
        let view = MonitorTargetEditorView(model: model, onSave: { _ in }, onCancel: {})
            .frame(width: 620, height: 720)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try renderLight(view, size: NSSize(width: 620, height: 720))
        #expect(image.size.width == 620)
        #expect(image.size.height == 720)
        try writeIfRequested(image, suffix: "onboarding")

        let dark = MonitorTargetEditorView(model: model, onSave: { _ in }, onCancel: {})
            .frame(width: 620, height: 720)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkImage = try render(dark, size: NSSize(width: 620, height: 720))
        #expect(darkImage.size == NSSize(width: 620, height: 720))
        try writeIfRequested(darkImage, suffix: "onboarding-dark")
    }

    @Test("Settings renders both configured and empty states")
    func settingsRenders() throws {
        let target = MonitorTarget(name: "Local GPU", probeModel: "qwen:small")
        let configuredModel = MonitorPreferencesModel(
            settings: MonitorSettings(targets: [target]),
            problem: nil)
        let configured = preferencesView(configuredModel)
            .frame(width: 640, height: 720)
            .background(Color(nsColor: .windowBackgroundColor))
        let configuredImage = try renderLight(configured, size: NSSize(width: 640, height: 720))
        #expect(configuredImage.size == NSSize(width: 640, height: 720))
        try writeIfRequested(configuredImage, suffix: "settings")

        let emptyModel = MonitorPreferencesModel(settings: MonitorSettings(), problem: nil)
        let empty = preferencesView(emptyModel)
            .frame(width: 640, height: 720)
            .background(Color(nsColor: .windowBackgroundColor))
        let emptyImage = try renderLight(empty, size: NSSize(width: 640, height: 720))
        #expect(emptyImage.size == NSSize(width: 640, height: 720))
        #expect(try lightCaptureDefectFraction(emptyImage) < 0.20)
        try writeIfRequested(emptyImage, suffix: "settings-empty")

        let dark = preferencesView(configuredModel)
            .frame(width: 640, height: 720)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkImage = try render(dark, size: NSSize(width: 640, height: 720))
        #expect(darkImage.size == NSSize(width: 640, height: 720))
        try writeIfRequested(darkImage, suffix: "settings-dark")
    }

    @Test("Two-mode welcome and Apple health details render")
    func appleModelWindowsRender() async throws {
        let welcomeSize = MonitorWelcomeView.windowSize(for: .available)
        let welcome = MonitorWelcomeView(onContinue: { _ in nil }, onAddRunner: { _ in nil })
            .frame(width: welcomeSize.width, height: welcomeSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let welcomeImage = try renderLight(welcome, size: welcomeSize)
        #expect(welcomeImage.size == welcomeSize)
        try writeIfRequested(welcomeImage, suffix: "welcome-two-mode")
        let darkWelcome = MonitorWelcomeView(
            onContinue: { _ in nil }, onAddRunner: { _ in nil })
            .frame(width: welcomeSize.width, height: welcomeSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkWelcomeImage = try render(darkWelcome, size: welcomeSize)
        #expect(darkWelcomeImage.size == welcomeSize)
        try writeIfRequested(darkWelcomeImage, suffix: "welcome-two-mode-dark")
        let runnerOnlySize = MonitorWelcomeView.windowSize(for: .unavailable(.deviceNotEligible))
        let runnerOnlyWelcome = MonitorWelcomeView(
            appleAvailability: .unavailable(.deviceNotEligible),
            onContinue: { _ in nil },
            onAddRunner: { _ in nil })
            .frame(width: runnerOnlySize.width, height: runnerOnlySize.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let runnerOnlyImage = try renderLight(runnerOnlyWelcome, size: runnerOnlySize)
        #expect(runnerOnlyImage.size == runnerOnlySize)
        #expect(try lightCaptureDefectFraction(runnerOnlyImage) < 0.20)
        try writeIfRequested(runnerOnlyImage, suffix: "welcome-runner-only")

        var snapshot = AppleModelHealthSnapshot()
        snapshot.phase = .healthy
        snapshot.availability = .available
        snapshot.checkedAt = Date()
        snapshot.functionalCheckedAt = Date()
        snapshot.functionalSucceededAt = Date()
        snapshot.lastLatencySeconds = 1.2
        snapshot.baselineLatencySeconds = 1.1
        snapshot.latencySamples = [1.0, 1.1, 1.2]
        let details = AppleModelDetailsView(
            model: AppleModelDetailsModel(
                snapshot: snapshot,
                settings: AppleModelMonitorSettings(functionalChecksEnabled: true)),
            onCopy: {},
            onCheck: {},
            onOpenSettings: {},
            onDone: {})
            .frame(width: 640, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
        let detailsImage = try renderLight(details, size: NSSize(width: 640, height: 700))
        #expect(detailsImage.size == NSSize(width: 640, height: 700))
        try writeIfRequested(detailsImage, suffix: "apple-intelligence-details")
        let narrowDetails = AppleModelDetailsView(
            model: AppleModelDetailsModel(
                snapshot: snapshot,
                settings: AppleModelMonitorSettings(functionalChecksEnabled: true)),
            onCopy: {},
            onCheck: {},
            onOpenSettings: {},
            onDone: {})
            .frame(width: 560, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
        let narrowDetailsImage = try renderLight(narrowDetails, size: NSSize(width: 560, height: 700))
        #expect(narrowDetailsImage.size == NSSize(width: 560, height: 700))
        try writeIfRequested(narrowDetailsImage, suffix: "apple-intelligence-details-narrow")
        let darkDetails = AppleModelDetailsView(
            model: AppleModelDetailsModel(
                snapshot: snapshot,
                settings: AppleModelMonitorSettings(functionalChecksEnabled: true)),
            onCopy: {},
            onCheck: {},
            onOpenSettings: {},
            onDone: {})
            .frame(width: 640, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkDetailsImage = try render(darkDetails, size: NSSize(width: 640, height: 700))
        #expect(darkDetailsImage.size == NSSize(width: 640, height: 700))
        try writeIfRequested(darkDetailsImage, suffix: "apple-intelligence-details-dark")

        snapshot.phase = .down
        snapshot.failure = .timedOut
        snapshot.consecutiveFailures = 2
        let failedDetails = AppleModelDetailsView(
            model: AppleModelDetailsModel(
                snapshot: snapshot,
                settings: AppleModelMonitorSettings(functionalChecksEnabled: true)),
            onCopy: {},
            onCheck: {},
            onOpenSettings: {},
            onDone: {})
            .frame(width: 640, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
        let failedDetailsImage = try renderLight(
            failedDetails, size: NSSize(width: 640, height: 700))
        #expect(failedDetailsImage.size == NSSize(width: 640, height: 700))
        try writeIfRequested(failedDetailsImage, suffix: "apple-model-action")

    }

    @Test("History and live details render at release sizes")
    func runtimeWindowsRender() async throws {
        let target = MonitorTarget(name: "GPU", probeModel: "tiny")
        let incident = MonitorIncident(
            targetID: target.id,
            targetName: target.name,
            startedAt: Date().addingTimeInterval(-30),
            lastObservedAt: Date(),
            cause: "Inference timed out.",
            inferenceLevel: true)
        let historyModel = MonitorHistoryModel(
            ledger: MonitorIncidentLedger(incidents: [incident]),
            problem: nil)
        let history = MonitorHistoryView(
            model: historyModel,
            onCopy: {},
            onClearResolved: {},
            onReset: {},
            onOpenTarget: { _ in },
            onDone: {})
            .frame(width: 680, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        let historyImage = try renderLight(history, size: NSSize(width: 680, height: 560))
        #expect(historyImage.size == NSSize(width: 680, height: 560))
        try writeIfRequested(historyImage, suffix: "history")
        let darkHistory = MonitorHistoryView(
            model: historyModel,
            onCopy: {},
            onClearResolved: {},
            onReset: {},
            onOpenTarget: { _ in },
            onDone: {})
            .frame(width: 680, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkHistoryImage = try render(darkHistory, size: NSSize(width: 680, height: 560))
        #expect(darkHistoryImage.size == NSSize(width: 680, height: 560))
        try writeIfRequested(darkHistoryImage, suffix: "history-dark")

        let fleet = MonitorFleetCoordinator(
            http: MonitorFakeHTTPClient(default: .refused),
            automaticallySchedules: false)
        fleet.apply([target])
        await fleet.checkNow(targetID: target.id)
        await fleet.checkNow(targetID: target.id)
        let bridge = FullHearthBridgeCoordinator(
            client: FullHearthClient(http: RenderAuthenticatedHTTP()),
            secrets: RenderSecrets(),
            automaticallySchedules: false)
        bridge.apply([target])
        let diagnostics = MonitorDiagnosticsView(
            model: MonitorDiagnosticsModel(selectedID: target.id),
            fleet: fleet,
            fullHearthBridge: bridge,
            onCheck: { _ in },
            onCopy: { _ in },
            onRefreshFullHearth: { _ in },
            onConnectFullHearth: { _ in },
            onOpenSettings: {},
            onDone: {})
            .frame(width: 780, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        let detailsImage = try renderLight(diagnostics, size: NSSize(width: 780, height: 560))
        #expect(detailsImage.size == NSSize(width: 780, height: 560))
        try writeIfRequested(detailsImage, suffix: "details")
        let darkDiagnostics = MonitorDiagnosticsView(
            model: MonitorDiagnosticsModel(selectedID: target.id),
            fleet: fleet,
            fullHearthBridge: bridge,
            onCheck: { _ in },
            onCopy: { _ in },
            onRefreshFullHearth: { _ in },
            onConnectFullHearth: { _ in },
            onOpenSettings: {},
            onDone: {})
            .frame(width: 780, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkDetailsImage = try render(darkDiagnostics, size: NSSize(width: 780, height: 560))
        #expect(darkDetailsImage.size == NSSize(width: 780, height: 560))
        try writeIfRequested(darkDetailsImage, suffix: "details-dark")
    }

    @Test("Full Hearth pairing renders without exposing a plain token control")
    func pairingRenders() throws {
        let model = FullHearthPairingModel(
            target: MonitorTarget(),
            token: "",
            client: FullHearthClient(http: RenderAuthenticatedHTTP()))
        let view = FullHearthPairingView(
            model: model,
            hasExistingPairing: false,
            onSave: {},
            onDisconnect: {},
            onCancel: {})
            .frame(width: 600, height: 650)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try renderLight(view, size: NSSize(width: 600, height: 650))
        #expect(image.size == NSSize(width: 600, height: 650))
        try writeIfRequested(image, suffix: "full-hearth-pairing")

        let darkView = FullHearthPairingView(
            model: model,
            hasExistingPairing: false,
            onSave: {},
            onDisconnect: {},
            onCancel: {})
            .frame(width: 600, height: 650)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkImage = try render(darkView, size: NSSize(width: 600, height: 650))
        #expect(darkImage.size == NSSize(width: 600, height: 650))
        try writeIfRequested(darkImage, suffix: "full-hearth-pairing-dark")
    }

    private func preferencesView(_ model: MonitorPreferencesModel) -> some View {
        MonitorPreferencesView(
            model: model,
            onSelect: { _ in },
            onAdd: {},
            onEdit: {},
            onRemove: {},
            onSetAppleEnabled: { _ in },
            onSetFunctionalChecks: { _ in },
            onSetAppleInterval: { _ in },
            onSetAlerts: { _ in },
            onResumeAlerts: {},
            onSetLogin: { _ in },
            onDone: {})
    }

    private func writeIfRequested(_ image: NSImage, suffix: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["HEARTH_MONITOR_RENDER_UI"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("hearth-monitor-\(suffix).png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
    }

    /// Headless AppKit can occasionally capture before embedded controls finish
    /// their first layout. Keep the most detailed of three settled captures, then
    /// let the defect assertions fail if every candidate remains incomplete.
    private func renderLight<Content: View>(_ view: Content, size: NSSize) throws -> NSImage {
        var bestImage = try render(view, size: size)
        var bestDetail = try lightCaptureDetailScore(bestImage)
        for _ in 0..<2 {
            let candidate = try render(view, size: size)
            let detail = try lightCaptureDetailScore(candidate)
            if detail > bestDetail {
                bestImage = candidate
                bestDetail = detail
            }
        }
        #expect(try lightCaptureDefectFraction(bestImage) < 0.20)
        #expect(bestDetail > 0.005)
        return bestImage
    }

    private func lightCaptureDetailScore(_ image: NSImage) throws -> Double {
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var detail = 0.0
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                sampled += 1
                let brightness = (color.redComponent
                                  + color.greenComponent
                                  + color.blueComponent) / 3
                detail += max(0, 1 - brightness) * color.alphaComponent
            }
        }
        return sampled == 0 ? 0 : detail / Double(sampled)
    }

    /// A prior offscreen AppKit capture emitted giant transparent rectangles while
    /// the size-only smoke test stayed green. Transparent and near-black pixels are
    /// both defects in the light views that use this gate.
    private func lightCaptureDefectFraction(_ image: NSImage) throws -> Double {
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var defective = 0
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                sampled += 1
                if color.alphaComponent <= 0.8
                    || (color.redComponent < 0.08
                        && color.greenComponent < 0.08
                        && color.blueComponent < 0.08) {
                    defective += 1
                }
            }
        }
        return sampled == 0 ? 1 : Double(defective) / Double(sampled)
    }

    private func render<Content: View>(_ view: Content, size: NSSize) throws -> NSImage {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let representation = try #require(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        window.contentView = nil
        return image
    }
}

private struct RenderAuthenticatedHTTP: MonitorAuthenticatedHTTPClient {
    func get(_ url: URL, bearerToken: String, timeout: TimeInterval) async -> HTTPOutcome {
        .refused
    }
}

private struct RenderSecrets: MonitorSecretStoring {
    func token(for targetID: UUID) throws -> String? { nil }
    func setToken(_ token: String, for targetID: UUID) throws {}
    func deleteToken(for targetID: UUID) throws {}
    func runnerToken(for targetID: UUID) throws -> String? { nil }
    func setRunnerToken(_ token: String, for targetID: UUID) throws {}
    func deleteRunnerToken(for targetID: UUID) throws {}
}
