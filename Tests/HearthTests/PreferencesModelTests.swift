// SPDX-License-Identifier: MIT

import AppKit
import SupervisorCore
import SwiftUI
import Testing
@testable import Hearth

@MainActor
struct PreferencesModelTests {
    @Test func failedSaveKeepsEditsAndSuccessfulSaveUpdatesBaseline() throws {
        let model = PreferencesModel(HearthConfig())
        let original = model.baseline
        model.config.port = 12434
        model.save { _ in false }
        #expect(model.baseline == original)
        #expect(model.config.port == 12434)
        #expect(model.status.contains("edits are still here"))
        let view = PreferencesView(model: model, onSave: { _ in false }, onClose: {})
            .frame(width: 560, height: 640)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try render(view, size: NSSize(width: 560, height: 640))
        try export(image, name: "preferences-save-failure")
        model.save { _ in true }
        #expect(model.baseline == model.config)
        #expect(model.status.contains("Reload requested"))
    }

    @Test func managedMLXCannotBeSavedWithoutAModel() {
        let model = PreferencesModel(HearthConfig(runner: "mlx", mode: "managed", port: 8080))
        #expect(!model.canSave)
        #expect(model.blockingDiagnostics.contains { $0.message.contains("requires mlxModel") })

        model.config.mlxModel = "mlx-community/test"
        #expect(model.canSave)
    }

    @Test func attachedMLXDoesNotDemandAManagedStartupModel() {
        let model = PreferencesModel(HearthConfig(runner: "mlx", mode: "attached", port: 8080))
        #expect(model.canSave)
    }

    @Test func managedMLXPreferencesRenderAtTheReleaseWindowSize() throws {
        let model = PreferencesModel(HearthConfig(runner: "mlx", mode: "managed", port: 8080))
        let view = PreferencesView(model: model, onSave: { _ in true }, onClose: {})
            .frame(width: 500, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try render(view, size: NSSize(width: 500, height: 620))
        #expect(image.size == NSSize(width: 500, height: 620))

        if let directory = ProcessInfo.processInfo.environment["HEARTH_RENDER_UI"],
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("hearth-preferences-mlx.png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        }
    }

    @Test func focusedTabsAndWelcomeRenderInBothAppearances() throws {
        for dark in [false, true] {
            for page in PreferencesModel.Page.allCases {
                var config = HearthConfig()
                config.mode = "attached"
                config.port = 9 // isolated rendering must not query a normal runner
                config.metricsProxyEnabled = true
                config.probeModel = "qwen2.5:0.5b"
                config.controlEnabled = true
                config.controlToken = "fixture-token-not-a-real-secret"
                let model = PreferencesModel(config)
                model.page = page
                let view = PreferencesView(model: model, onSave: { _ in true }, onClose: {})
                    .frame(width: 560, height: 640)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(dark ? .dark : .light)
                let image = try render(view, size: NSSize(width: 560, height: 640))
                try export(image, name: "preferences-\(page.rawValue)-\(dark ? "dark" : "light")")
            }
            for managed in [false, true] {
                let view = WelcomeView(runner: "ollama", managed: managed,
                    foundPath: "/opt/homebrew/bin/ollama", installHint: "brew install ollama",
                    collisionWarning: nil, onSwitchToAttached: {}, onEnableNotifications: {},
                    onOpenPreferences: {}, onDone: {})
                    .frame(width: 460, height: 430)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(dark ? .dark : .light)
                let image = try render(view, size: NSSize(width: 460, height: 430))
                try export(image, name: "welcome-\(managed ? "managed" : "attached")-\(dark ? "dark" : "light")")
            }
        }
    }

    private func export(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["HEARTH_RENDER_UI"] else { return }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
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
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
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
