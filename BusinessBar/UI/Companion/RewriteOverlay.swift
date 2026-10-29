import AppKit
import BusinessBarCore
import SwiftUI

// MARK: - RewriteOverlayController

/// Controller for the rewrite result window: a small floating panel that
/// shows the rewritten text with Replace / Copy actions. Never replaces the
/// user's text automatically; Replace is an explicit button.
///
/// MainActor: panel ordering and pasteboard writes are AppKit-side, and
/// SwiftUI walks the main menu on app activation. A background Task here
/// crashed the app once (NSMenu mutated off the main thread).
@MainActor
final class RewriteOverlayController: NSObject, NSWindowDelegate {
    static let shared = RewriteOverlayController()

    private var panel: NSPanel?
    private var selectionService = SelectionService()

    /// Remembers where the captured text came from so Replace is offered
    /// only when the AX path captured it.
    private var currentSelection: SelectionService.CapturedSelection?

    // MARK: - Present

    func present(
        original: String,
        rewritten: String,
        templateName: String,
        selection: SelectionService.CapturedSelection?
    ) {
        currentSelection = selection
        AppLogger.info(
            "overlay present template=\(templateName) bytes=\(rewritten.utf8.count) viaAX=\(selection?.viaAccessibility ?? false)",
            category: "Companion"
        )

        let view = RewriteOverlayView(
            original: original,
            rewritten: rewritten,
            templateName: templateName,
            onReplace: { [weak self] in self?.performReplace() },
            onCopy: { [weak self] in
                self?.copyToClipboard()
                self?.dismiss()
            },
            onClose: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: view)
        let contentSize = NSSize(width: 420, height: 280)

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        newPanel.isMovable = true
        newPanel.isReleasedWhenClosed = false
        newPanel.delegate = self
        newPanel.contentView = hosting
        newPanel.setFrameAutosaveName("CompanionRewriteOverlay")

        panel?.close()
        panel = newPanel

        position(newPanel, nearTextOf: selection)
        newPanel.makeKeyAndOrderFront(nil)
        // No NSApp.activate: the overlay is a nonactivating panel, and
        // activating would hand key focus to BusinessBar so the AX replace
        // targets our own window instead of the app being rewritten.
    }

    private func position(_ panel: NSPanel, nearTextOf selection: SelectionService.CapturedSelection?) {
        // Anchor near the mouse: the trigger is a global shortcut, and the
        // selection is usually under or near the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screenContaining(mouse) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var origin = mouse
        origin.x -= panel.frame.width / 2
        origin.y -= panel.frame.height + 16
        if origin.y < visible.minY { origin.y = mouse.y + 16 }
        origin.x = origin.x.clamped(to: visible.minX...visible.maxX - panel.frame.width)
        origin.y = origin.y.clamped(to: visible.minY...visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Actions

    func performReplace() {
        guard let panel,
              let rewritten = (panel.contentView as? NSHostingView<RewriteOverlayView>)?
                  .rootView.rewritten
        else {
            // Fallback: copy when we cannot reach the rewritten text.
            AppLogger.error("overlay replace: content unavailable, copying instead", category: "Companion")
            copyToClipboard()
            dismiss()
            return
        }

        let selection = currentSelection
        // Dismiss first, replace second. The panel is a nonactivating panel,
        // but it is the key window while visible, and both the AX focused
        // element and synthetic keystrokes follow the key window: replacing
        // with the panel up wrote into our own buttons and beeped on Cmd+V
        // in the wrong window. (Maccy and Clipy paste only after their
        // panel closes.)
        dismiss()

        Task { [weak self] in
            let succeeded: Bool
            if let selection {
                succeeded = await self?.selectionService.replaceSelectionInOwner(
                    of: selection, with: rewritten
                ) ?? false
            } else {
                succeeded = await self?.selectionService.replaceSelection(with: rewritten) ?? false
            }
            if succeeded {
                AppLogger.info("overlay replace: AX write succeeded", category: "Companion")
            } else {
                AppLogger.error("overlay replace: AX write failed, copying instead", category: "Companion")
                self?.copyFallbackToClipboard(rewritten)
            }
        }
    }

    private func copyFallbackToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLogger.info("overlay copy: \(text.utf8.count) bytes on pasteboard", category: "Companion")
    }

    private func copyToClipboard() {
        guard let panel,
              let rewritten = (panel.contentView as? NSHostingView<RewriteOverlayView>)?
                  .rootView.rewritten
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(rewritten, forType: .string)
        AppLogger.info("overlay copy: \(rewritten.utf8.count) bytes on pasteboard", category: "Companion")
    }

    private func dismiss() {
        AppLogger.info("overlay dismiss", category: "Companion")
        panel?.orderOut(nil)
        panel = nil
        currentSelection = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        panel = nil
        currentSelection = nil
    }
}

// MARK: - NSScreen helper

private extension NSScreen {
    /// The screen containing `point`, if any.
    static func screenContaining(_ point: NSPoint) -> NSScreen? {
        screens.first { NSPointInRect(point, $0.frame) }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - RewriteOverlayView

struct RewriteOverlayView: View {
    let original: String
    let rewritten: String
    let templateName: String
    let onReplace: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var showsOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(templateName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Show original") { showsOriginal.toggle() }
                    .controlSize(.small)
            }
            .padding([.horizontal, .top])

            ScrollView {
                Text(showsOriginal ? original : rewritten)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }

            HStack {
                Button("Replace", action: onReplace)
                    .keyboardShortcut(.defaultAction)
                Button("Copy", action: onCopy)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .background(.background)
    }
}
