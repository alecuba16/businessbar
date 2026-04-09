import AppKit
import SwiftUI

/// Minimal toast shown when a monitored app's badge count increases.
/// Displayed inside an arrow-less NSPopover anchored to the app's badge
/// status item and auto-dismissed after 3 seconds.
struct ToastView: View {
    let icon: NSImage?
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            }
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
