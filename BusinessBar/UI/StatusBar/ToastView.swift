import AppKit
import BusinessBarCore
import SwiftUI

/// Minimal toast shown when a monitored app's badge increases.
/// Displayed inside an arrow-less NSPopover anchored to the app's badge
/// status item and auto-dismissed after 3 seconds.
/// A dot badge (unknown count) renders the icon with a small red dot: the
/// honest state has no number to print.
struct ToastView: View {
    let icon: NSImage?
    let badge: BadgeValue?

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .overlay(alignment: .topTrailing) {
                        if badge == .unknown {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 1)
                                        .frame(width: 9, height: 9)
                                )
                                .offset(x: 2, y: -2)
                        }
                    }
            }
            if let text = badge?.toastText {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
