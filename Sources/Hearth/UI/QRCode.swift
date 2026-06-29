// SPDX-License-Identifier: MIT

import AppKit
import CoreImage

/// Generates a scannable QR code from a string (the control URL), so the menu can
/// show a code you point your phone at instead of retyping the address. Uses
/// CoreImage's built-in generator, no third-party dependency. The output is black
/// modules on a white background, so it scans on a dark menu too.
enum QRCode {
    static func image(for string: String, size: CGFloat) -> NSImage? {
        // ASCII keeps the code as small (low-density) as possible; a control URL
        // is always ASCII, but fall back to UTF-8 to never return nil on content.
        guard let data = string.data(using: .ascii) ?? string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }

        // Scale up with no interpolation so the modules stay crisp squares.
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
