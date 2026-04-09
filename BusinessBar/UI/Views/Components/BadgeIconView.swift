import AppKit
import SwiftUI

// MARK: - BadgeIconView
// A SwiftUI view that renders an app icon with an optional red badge circle
// overlay in the top-right corner, matching the macOS dock badge style.

struct BadgeIconView: View {
    let icon: NSImage?
    let badgeCount: Int
    let iconSize: CGFloat

    init(icon: NSImage?, badgeCount: Int, iconSize: CGFloat = 16) {
        self.icon = icon
        self.badgeCount = badgeCount
        self.iconSize = iconSize
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // App icon
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: iconSize, height: iconSize)

            // Badge bubble
            if badgeCount > 0 {
                BadgeBubble(count: badgeCount, iconSize: iconSize)
                    .offset(x: badgeOffset, y: -badgeOffset)
            }
        }
    }

    private var badgeOffset: CGFloat {
        iconSize * 0.18
    }
}

// MARK: - BadgeBubble

private struct BadgeBubble: View {
    let count: Int
    let iconSize: CGFloat

    var body: some View {
        Text(labelText)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 1)
            .background(Color.red)
            .clipShape(Capsule())
            .frame(minWidth: bubbleMinSize, minHeight: bubbleMinSize)
    }

    private var labelText: String {
        count > 99 ? "99+" : "\(count)"
    }

    private var fontSize: CGFloat { iconSize * 0.55 }
    private var bubbleMinSize: CGFloat { iconSize * 0.65 }
    private var horizontalPadding: CGFloat { count < 10 ? 1 : 2 }
}

// MARK: - NSImage convenience (status-bar rendering)

extension NSImage {
    /// Returns an NSImage combining `self` (at `iconSize`) with a red badge
    /// overlay, suitable for use in an NSStatusItem button.
    func statusBarImage(badgeCount: Int, iconSize: CGFloat = 16) -> NSImage {
        let totalSize = NSSize(width: iconSize + iconSize * 0.36,
                               height: iconSize + iconSize * 0.36)
        let result = NSImage(size: totalSize)
        result.lockFocus()

        // Draw base icon
        let iconRect = NSRect(x: 0, y: 0, width: iconSize, height: iconSize)
        draw(in: iconRect,
             from: NSRect(origin: .zero, size: size),
             operation: .sourceOver,
             fraction: 1.0)

        if badgeCount > 0 {
            // Badge circle dimensions
            let badgeDiameter: CGFloat = iconSize * 0.65
            let badgeRect = NSRect(
                x: totalSize.width - badgeDiameter,
                y: totalSize.height - badgeDiameter,
                width: badgeDiameter,
                height: badgeDiameter
            )

            // Draw red filled circle
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            // Draw count text
            let label = badgeCount > 99 ? "99+" : "\(badgeCount)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: badgeDiameter * 0.55),
                .foregroundColor: NSColor.white
            ]
            let attrStr = NSAttributedString(string: label, attributes: attrs)
            let textSize = attrStr.size()
            let textOrigin = NSPoint(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2
            )
            attrStr.draw(at: textOrigin)
        }

        result.unlockFocus()
        return result
    }
}
