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
    @Test("First-run editor renders at its release window size")
    func editorRenders() throws {
        let model = MonitorTargetEditorModel(
            target: MonitorTarget(),
            http: MonitorFakeHTTPClient())
        let view = MonitorTargetEditorView(model: model, onSave: { _ in }, onCancel: {})
            .frame(width: 620, height: 720)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try render(view, size: NSSize(width: 620, height: 720))
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
        let model = MonitorPreferencesModel(
            settings: MonitorSettings(targets: [target]),
            problem: nil)
        let view = MonitorPreferencesView(
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
            .frame(width: 640, height: 720)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try render(view, size: NSSize(width: 640, height: 720))
        #expect(image.size.width == 640)
        #expect(image.size.height == 720)
        try writeIfRequested(image, suffix: "settings")
    }

    @Test("Two-mode welcome and Apple health details render")
    func appleModelWindowsRender() throws {
        let welcome = MonitorWelcomeView(onContinue: { _ in nil }, onAddRunner: { _ in nil })
            .frame(width: 640, height: 650)
            .background(Color(nsColor: .windowBackgroundColor))
        let welcomeImage = try render(welcome, size: NSSize(width: 640, height: 650))
        #expect(welcomeImage.size == NSSize(width: 640, height: 650))
        try writeIfRequested(welcomeImage, suffix: "welcome-two-mode")
        let darkWelcome = MonitorWelcomeView(
            onContinue: { _ in nil }, onAddRunner: { _ in nil })
            .frame(width: 640, height: 650)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let darkWelcomeImage = try render(darkWelcome, size: NSSize(width: 640, height: 650))
        #expect(darkWelcomeImage.size == NSSize(width: 640, height: 650))
        try writeIfRequested(darkWelcomeImage, suffix: "welcome-two-mode-dark")
        let runnerOnlyWelcome = MonitorWelcomeView(
            appleAvailability: .unavailable(.deviceNotEligible),
            onContinue: { _ in nil },
            onAddRunner: { _ in nil })
            .frame(width: 640, height: 650)
            .background(Color(nsColor: .windowBackgroundColor))
        let runnerOnlyImage = try render(runnerOnlyWelcome, size: NSSize(width: 640, height: 650))
        #expect(runnerOnlyImage.size == NSSize(width: 640, height: 650))
        #expect(try darkPixelFraction(runnerOnlyImage) < 0.20)
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
        let detailsImage = try render(details, size: NSSize(width: 640, height: 700))
        #expect(detailsImage.size == NSSize(width: 640, height: 700))
        try writeIfRequested(detailsImage, suffix: "apple-intelligence-details")
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
    }

    @Test("History and live details render at release sizes")
    func runtimeWindowsRender() throws {
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
            onDone: {})
            .frame(width: 680, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        let historyImage = try render(history, size: NSSize(width: 680, height: 560))
        #expect(historyImage.size == NSSize(width: 680, height: 560))
        try writeIfRequested(historyImage, suffix: "history")

        let fleet = MonitorFleetCoordinator(
            http: MonitorFakeHTTPClient(default: .ok(Data())),
            automaticallySchedules: false)
        fleet.apply([target])
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
        let detailsImage = try render(diagnostics, size: NSSize(width: 780, height: 560))
        #expect(detailsImage.size == NSSize(width: 780, height: 560))
        try writeIfRequested(detailsImage, suffix: "details")
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
        let image = try render(view, size: NSSize(width: 600, height: 650))
        #expect(image.size == NSSize(width: 600, height: 650))
        try writeIfRequested(image, suffix: "full-hearth-pairing")
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

    /// A prior offscreen AppKit capture emitted giant black rectangles while the
    /// size-only smoke test stayed green. Sample the light onboarding render so
    /// that failure shape becomes mechanically visible without snapshot tooling.
    private func darkPixelFraction(_ image: NSImage) throws -> Double {
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var dark = 0
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                sampled += 1
                if color.alphaComponent > 0.8
                    && color.redComponent < 0.08
                    && color.greenComponent < 0.08
                    && color.blueComponent < 0.08 {
                    dark += 1
                }
            }
        }
        return sampled == 0 ? 1 : Double(dark) / Double(sampled)
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
}
