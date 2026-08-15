// SPDX-License-Identifier: MIT

import AppKit
import SupervisorCore
import SwiftUI
import Testing
@testable import Hearth

@MainActor
struct PreferencesModelTests {
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
        let view = PreferencesView(model: model, onSave: { _ in }, onClose: {})
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
