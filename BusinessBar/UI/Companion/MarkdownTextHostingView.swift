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
        apply(markdown, to: textView)
        return textView
    }

    func updateNSView(_ textView: MarkdownTextView, context: Context) {
        if textView.markdownTag != markdown {
            apply(markdown, to: textView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }

        // NSTextView has no intrinsic height. Its live container can also report zero during a resize,
        // so measure the same attributed text without changing the displayed container.
        let inset = nsView.textContainerInset
        let storage = NSTextStorage(attributedString: nsView.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(
            width: max(1, width - inset.width * 2),
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = nsView.textContainer?.lineFragmentPadding ?? 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: ceil(height + inset.height * 2))
    }

    private func apply(_ markdown: String, to textView: MarkdownTextView) {
        let attributed = MarkdownAttributedStringLoader.attributedString(for: markdown)
        textView.textStorage?.setAttributedString(attributed)
        textView.markdownTag = markdown
        // Stream updates can change the height returned by sizeThatFits.
        textView.invalidateIntrinsicContentSize()
    }
}

// MARK: - MarkdownTextView

/// NSTextView subclass routing link clicks through the scheme gate.
final class MarkdownTextView: NSTextView {
    var markdownTag: String = ""

    override func clicked(onLink link: Any, at charIndex: Int) {
        // Same gate as the rest of the chat: only these schemes open,
        // everything else a model emits stays inert.
        guard let url = link as? URL,
              let scheme = url.scheme?.lowercased(),
              MarkdownTextLinkPolicy.schemes.contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}
