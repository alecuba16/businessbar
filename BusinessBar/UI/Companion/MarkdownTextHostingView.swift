import AppKit
import SwiftUI

// MARK: - MarkdownTextHostingView

/// One non-editable NSTextView holding the whole reply as a single
/// selectable document. This is the piece SwiftUI cannot offer: its
/// markdown stack renders one Text per block and macOS selection never
/// crosses Text views. Links keep the scheme gate (only http, https,
/// mailto, tel open), clicks on disallowed schemes stay inert, and the
/// context menu keeps the native Copy plus the chat-wide actions.
struct MarkdownTextHostingView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.linkTarget = self
        context.coordinator.textView = textView
        apply(markdown, to: textView)
        return textView
    }

    func updateNSView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.textView = textView
        if textView.markdownTag != markdown {
            apply(markdown, to: textView)
        }
    }

    private func apply(_ markdown: String, to textView: MarkdownTextView) {
        let attributed = MarkdownAttributedStringLoader.attributedString(for: markdown)
        textView.textStorage?.setAttributedString(attributed)
        textView.markdownTag = markdown
        // Height follows content: SwiftUI asks for the intrinsic size
        // through fitted sizing, the container grows without a cap.
        textView.invalidateIntrinsicContentSize()
    }
}

// MARK: - MarkdownTextView

/// NSTextView subclass routing link clicks through the scheme gate.
final class MarkdownTextView: NSTextView {
    var markdownTag: String = ""
    var linkTarget: MarkdownTextHostingView?

    override func clicked(on link: Any) {
        guard let url = link as? URL else {
            super.clicked(on: link)
            return
        }
        // Same gate as the rest of the chat: only these schemes open,
        // everything else a model emits stays inert.
        guard let scheme = url.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}