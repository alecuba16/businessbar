import AppKit
import CoreImage

// MARK: - NSImage image transformations

public extension NSImage {
    // MARK: - Grayscale

    /// Returns a grayscale version of the image using CIColorControls.
    func grayscale() -> NSImage {
        guard let cgImage = cgImageRepresentation() else { return self }

        let ciImage = CIImage(cgImage: cgImage)
        let filter  = CIFilter(name: "CIColorControls")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: output.extent) else {
            return self
        }
        return NSImage(cgImage: result, size: size)
    }

    func grayscalePreservingAlpha() -> NSImage {
        guard let cgImage = cgImageRepresentation() else { return self }
        let ciImage = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let outputImage = filter.outputImage,
              let cgResult = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return self
        }

        let final = NSImage(size: size)
        final.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cgResult, size: size)
            .draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        final.unlockFocus()
        final.isTemplate = false
        return final
    }

    // MARK: - Invert (for dark mode)

    /// Returns a colour-inverted copy of the image using CIColorInvert.
    // public — inherits from `public extension NSImage` block above
    func inverted() -> NSImage {
        guard let cgImage = cgImageRepresentation() else { return self }

        let ciImage = CIImage(cgImage: cgImage)
        let filter  = CIFilter(name: "CIColorInvert")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)

        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: output.extent) else {
            return self
        }
        return NSImage(cgImage: result, size: size)
    }

    // MARK: - Tint

    /// Returns a copy of the image tinted with `color`, preserving alpha.
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.withAlphaComponent(0.5).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }

    // MARK: - Resize

    /// Returns a copy scaled to `targetSize`.
    func resized(to targetSize: NSSize) -> NSImage {
        NSImage(size: targetSize, flipped: false) { rect in
            self.draw(in: rect,
                      from: NSRect(origin: .zero, size: self.size),
                      operation: .copy,
                      fraction: 1.0)
            return true
        }
    }

    // MARK: - Adaptive dark-mode inversion

    /// Returns `self` in light mode and an inverted copy in dark mode.
    /// Useful for non-template badge icons that need to remain visible.
    func adaptedForAppearance(_ appearance: NSAppearance) -> NSImage {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? inverted() : self
    }

    // MARK: - Private helpers

    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    private var ciContext: CIContext { Self.sharedCIContext }

    /// Renders the NSImage into a CGImage for Core Image processing.
    private func cgImageRepresentation() -> CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
