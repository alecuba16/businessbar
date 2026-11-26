import AppKit
import CoreImage

public extension NSImage {
    /// Draws the image at menu bar size with a count bubble in the corner.
    /// `indicatorScale` grows or shrinks the bubble circle and its number font
    /// together (1.0 = the historical 10 pt bubble); the app icon itself is
    /// untouched, matching the dock style where the two sizes are independent.
    func withBadge(count: Int, indicatorScale: CGFloat = 1) -> NSImage {
        let scale = max(0.5, min(indicatorScale, 2))
        let badgeSize: CGFloat = 10 * scale
        let imageSize = NSSize(width: 18, height: 18)

        let newImage = NSImage(size: imageSize)
        newImage.lockFocus()

        let imageRect = NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        self.draw(in: imageRect)

        let label = count > 99 ? "99+" : "\(count)"
        let font = NSFont.systemFont(ofSize: 7 * scale, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]

        let textSize = label.size(withAttributes: attributes)
        let padding: CGFloat = 1
        let capsuleWidth = max(badgeSize, textSize.width + padding * 2)

        let badgeRect = NSRect(
            x: imageSize.width - capsuleWidth,
            y: imageSize.height - badgeSize,
            width: capsuleWidth,
            height: badgeSize
        )

        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize / 2, yRadius: badgeSize / 2).fill()

        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        label.draw(in: textRect, withAttributes: attributes)

        newImage.unlockFocus()
        // Must be false: template images are rendered as a solid-colour silhouette
        // by AppKit, which destroys the red badge and app-icon colours.
        newImage.isTemplate = false

        return newImage
    }

    /// Draws the image with a plain dot in the corner: notifications exist but
    /// the Dock label carries no count. The 1 pt white ring keeps the red dot
    /// readable on dark app icons, where red-on-dark alone can disappear.
    /// `indicatorScale` matches withBadge's scale so the dot and the number
    /// bubble resize consistently under one preference.
    func withDot(indicatorScale: CGFloat = 1) -> NSImage {
        let scale = max(0.5, min(indicatorScale, 2))
        let imageSize = NSSize(width: 18, height: 18)

        let newImage = NSImage(size: imageSize)
        newImage.lockFocus()

        let imageRect = NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        self.draw(in: imageRect)

        let dotDiameter: CGFloat = 7 * scale
        let ringDiameter: CGFloat = dotDiameter + 2
        let ringRect = NSRect(
            x: imageSize.width - ringDiameter,
            y: imageSize.height - ringDiameter,
            width: ringDiameter,
            height: ringDiameter
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: ringRect).fill()

        let dotRect = NSRect(
            x: ringRect.midX - dotDiameter / 2,
            y: ringRect.midY - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        newImage.unlockFocus()
        // Same as withBadge: template rendering would flatten the dot to a
        // silhouette and lose the ring contrast.
        newImage.isTemplate = false

        return newImage
    }

    func grayscale() -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let ciImage = CIImage(cgImage: cgImage)

        guard let filter = CIFilter(name: "CIColorControls") else {
            return nil
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let rep = NSCIImageRep(ciImage: outputImage)
        let newImage = NSImage(size: rep.size)
        newImage.addRepresentation(rep)
        // Must be false: template images are rendered as a white/black silhouette,
        // destroying the grey tint that grayscale() is meant to produce.
        newImage.isTemplate = false

        return newImage
    }
}
