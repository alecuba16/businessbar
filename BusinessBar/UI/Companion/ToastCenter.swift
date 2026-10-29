import AppKit
import SwiftUI

// MARK: - ToastCenter

/// Shows short status toasts just under the menu bar. Used to confirm a
/// template shortcut fired and to surface rewrite failures that have no
/// other visible surface.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private var panel: NSPanel?

    private init() {}

    /// Shows a toast for the given duration. A new toast replaces the old
    /// one so rapid triggers cannot stack panels.
    func show(_ text: String, icon: String = "sparkles", duration: TimeInterval = 2.0) {
        dismiss()

        let view = StatusToastView(text: text, icon: icon)
        let hosting = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting

        // Centered horizontally on the main screen, under the menu bar.
        if let visible = NSScreen.main?.visibleFrame {
            let size = hosting.fittingSize
            panel.setFrame(
                NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.maxY - size.height - 8,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        }

        panel.orderFrontRegardless()
        self.panel = panel

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - StatusToastView

private struct StatusToastView: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
