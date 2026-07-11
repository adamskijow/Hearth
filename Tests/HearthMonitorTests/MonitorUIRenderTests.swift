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
            onSetAlerts: { _ in },
            onResumeAlerts: {},
            onSetLogin: { _ in },
            onDone: {})
            .frame(width: 620, height: 640)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try render(view, size: NSSize(width: 620, height: 640))
        #expect(image.size.width == 620)
        #expect(image.size.height == 640)
        try writeIfRequested(image, suffix: "settings")
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
        try png.write(to: url, options: .atomic)
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
