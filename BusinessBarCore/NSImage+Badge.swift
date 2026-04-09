import AppKit
import CoreImage

public extension NSImage {
    func withBadge(count: Int) -> NSImage {
        let badgeSize: CGFloat = 16
        let imageSize = NSSize(width: 18, height: 18)

        let newImage = NSImage(size: imageSize)
        newImage.lockFocus()

        let imageRect = NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        self.draw(in: imageRect)

        let badgeRect = NSRect(
            x: imageSize.width - badgeSize,
            y: imageSize.height - badgeSize,
            width: badgeSize,
            height: badgeSize
        )

        NSColor.systemRed.setFill()
        let badgePath = NSBezierPath(ovalIn: badgeRect)
        badgePath.fill()

        let countString = count > 99 ? "99+" : "\(count)"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]

        let textSize = countString.size(withAttributes: attributes)
        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )

        countString.draw(in: textRect, withAttributes: attributes)

        newImage.unlockFocus()
        // Must be false: template images are rendered as a solid-colour silhouette
        // by AppKit, which destroys the red badge and app-icon colours.
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
