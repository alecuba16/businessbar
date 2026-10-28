import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

/// Native composer for the chat input. A SwiftUI TextField with a
/// vertical axis inside a ScrollView clips long lines instead of
/// wrapping, hides its scroller when idle, and never scrolls to the
/// caret while typing. NSTextView wraps at the exact box width, keeps
/// a scroller that shows both edges at once, and scrolls the caret into
/// view as lines are added.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusRequest: Int
    var onReturn: () -> Void
    var onPaste: (NSPasteboard) -> Void
    var onContentHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> ComposerScrollView {
        let textView = ComposerNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // Wrapping recipe: the container width tracks the text view
        // frame, the text view tracks the scroll view width, and the
        // height grows without limit so the layout never clips.
        textView.textContainer!.widthTracksTextView = true
        textView.textContainer!.heightTracksTextView = false
        textView.textContainer!.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scroll = ComposerScrollView()
        scroll.documentView = textView
        // Overlay scroller instead of the classic inset: the text can
        // use the full box width edge to edge, and the arrows show both
        // edges at once, so it is always clear whether more text sits
        // above or below.
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .mini
        scroll.verticalScroller?.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.scrollView = scroll
        textView.delegate = coordinator
        textView.onReturn = { [weak coordinator] in
            coordinator?.parent?.onReturn()
        }
        textView.onPaste = { [weak coordinator] pasteboard in
            coordinator?.parent?.onPaste(pasteboard)
        }
        textView.onDidMoveToWindow = { [weak coordinator] in
            coordinator?.applyPendingFocus()
            coordinator?.syncDocumentHeight()
            coordinator?.syncScrollerState()
        }
        scroll.onFrameChange = { [weak coordinator] _ in
            coordinator?.syncDocumentHeight()
            coordinator?.syncScrollerState()
        }

        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        if textView.string != text {
            coordinator.setTextProgrammatic(text, into: textView)
        }

        if focusRequest != coordinator.appliedFocusRequest {
            coordinator.appliedFocusRequest = focusRequest
            if let window = textView.window {
                window.makeFirstResponder(textView)
            } else {
                coordinator.pendingFocus = true
            }
        }

        coordinator.syncDocumentHeight()
        coordinator.reportHeight()
        coordinator.syncScrollerState()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView?
        var textView: ComposerNSTextView?
        var scrollView: ComposerScrollView?
        var pendingFocus = false
        var appliedFocusRequest = 0
        private var reportingHeight = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func applyPendingFocus() {
            guard pendingFocus, let textView else { return }
            pendingFocus = false
            textView.window?.makeFirstResponder(textView)
        }

        func setTextProgrammatic(_ newText: String, into textView: ComposerNSTextView) {
            let selected = textView.selectedRange()
            let scrollOrigin = textView.visibleRect.origin
            textView.string = newText
            let clamped = NSRange(
                location: min(selected.location, (newText as NSString).length),
                length: 0
            )
            textView.setSelectedRange(clamped)
            textView.scroll(scrollOrigin)
        }

        /// The document view must be at least as tall as the laid-out
        /// text, otherwise lines below its frame are never rendered and
        /// caret scrolling breaks. It also fills the visible area when
        /// the text is short, so the scroller knob state is honest.
        func syncDocumentHeight() {
            guard let textView, let scroll = scrollView else { return }
            let container = textView.textContainer!
            textView.layoutManager?.ensureLayout(for: container)
            let usedHeight = textView.layoutManager?.usedRect(for: container).height ?? 0
            let visibleHeight = scroll.contentView.bounds.height
            let newHeight = max(
                usedHeight + textView.textContainerInset.height * 2,
                visibleHeight
            )
            if abs(textView.frame.height - newHeight) > 0.5 {
                var frame = textView.frame
                frame.size.height = newHeight
                textView.frame = frame
            }
        }

        func reportHeight() {
            guard let textView, let parent, !reportingHeight else { return }
            reportingHeight = true
            defer { reportingHeight = false }
            let container = textView.textContainer!
            textView.layoutManager?.ensureLayout(for: container)
            let used = textView.layoutManager?.usedRect(for: container) ?? .zero
            // Inset plus a small epsilon keeps the caret line fully
            // visible at the smallest box height.
            let height = used.height + textView.textContainerInset.height * 2 + 2
            parent.onContentHeight(height)
        }

        // The scroller mirrors the document edge situation: both
        // arrows enabled while the text overflows, each arrow disabled
        // at its own edge, both disabled once everything fits. Derived
        // from geometry on every content or frame change, so the
        // indicator is honest without manual event wiring.
        func syncScrollerState() {
            guard let textView, let scroll = scrollView,
                  let scroller = scroll.verticalScroller else { return }
            let overflow = textView.frame.height > scroll.contentView.bounds.height + 0.5
            guard overflow else {
                scroller.doubleValue = 0
                scroller.isEnabled = false
                scroller.knobProportion = 1
                return
            }
            let content = scroll.contentView
            let docHeight = content.documentView?.frame.height ?? 0
            let travel = docHeight - content.bounds.height
            guard travel > 0 else {
                scroller.doubleValue = 0
                scroller.isEnabled = false
                scroller.knobProportion = 1
                return
            }
            scroller.isEnabled = true
            scroller.doubleValue = content.bounds.origin.y / travel
            scroller.knobProportion = content.bounds.height / docHeight
        }

        // Every text change keeps the caret line on screen: typing
        // past the bottom scrolls instead of hiding the line being
        // written.
        func scrollCaretIntoView() {
            guard let textView else { return }
            textView.scrollRangeToVisible(
                NSRange(location: textView.selectedRange().location, length: 0)
            )
        }

        func textDidChange(_ notification: Notification) {
            parent?.text = textView?.string ?? ""
            syncDocumentHeight()
            reportHeight()
            scrollCaretIntoView()
            syncScrollerState()
        }

        func textDidChangeSelection(_ notification: Notification) {
            scrollCaretIntoView()
        }
    }
}

/// Reports frame size changes so the document view height follows the
/// scroll view when the panel or the composer cap resizes.
final class ComposerScrollView: NSScrollView {
    var onFrameChange: ((NSScrollView) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onFrameChange?(self)
    }
}

/// NSTextView subclass that intercepts Return (send vs newline),
/// routes image pastes to the chat's staging pipeline, and applies a
/// focus request raised before the view had a window.
final class ComposerNSTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onPaste: ((NSPasteboard) -> Void)?
    var onDidMoveToWindow: (() -> Void)?
    // Internal so validation harnesses can read the marker state.
    var markerLayers: [CATextLayer] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
    }

    override func layout() {
        super.layout()
        positionBreakMarkers()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        positionBreakMarkers()
    }

    // Wrap arrows at the end of each fragment the editor wrapped, the
    // same rounding-back glyph other editors use, plus a paragraph mark
    // after the last glyph of a line a Return created. Hard breaks stay
    // visibly distinct from wraps: an arrow means "this line continues",
    // the paragraph mark means "you pressed Return here". Layers travel
    // with the document, so scrolled-away markers keep their positions.
    private func positionBreakMarkers() {
        guard let container = textContainer, let layoutManager = layoutManager else { return }
        layoutManager.ensureLayout(for: container)
        let string = (self.string as NSString)
        var keptLayers: [CATextLayer] = []

        // Enumerate layout fragments: each is one visual row. A row whose
        // text does not end in a newline continues on the next row, which
        // is exactly a wrap.
        var glyph = 0
        let totalGlyphs = layoutManager.numberOfGlyphs
        while glyph < totalGlyphs {
            let rangePointer = UnsafeMutablePointer<NSRange>.allocate(capacity: 1)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: rangePointer)
            let glyphRange = rangePointer.pointee
            rangePointer.deallocate()
            let fragmentEnd = glyphRange.location + glyphRange.length

            // Map the fragment's glyph span back to characters to see how
            // the row ends.
            let firstChar = mappedCharIndex(ofGlyph: glyphRange.location, in: string, layoutManager: layoutManager)
            let endChar = fragmentEnd >= totalGlyphs
                ? string.length
                : mappedCharIndex(ofGlyph: fragmentEnd, in: string, layoutManager: layoutManager)
            let rowEndsInNewline = endChar > firstChar && string.character(at: endChar - 1) == 0x0A
            // A row that neither ends in a newline nor is the last row
            // continues on the next row: that is a wrap, and its arrow
            // belongs here, at the end of the wrapped row. A row ending in
            // a newline never wraps onward, no matter where its line
            // started, so the arrow check keys on the row's own ending.
            if !rowEndsInNewline, fragmentEnd < totalGlyphs {
                keptLayers.append(
                    markerLayer("\u{21A9}", endOfRow: fragment, container: container)
                )
            } else if rowEndsInNewline {
                // The paragraph mark sits after the row's last drawn glyph,
                // not at the row edge: a full-width line and a half-empty
                // one both read correctly. The newline glyph itself spans
                // the whole remaining row, so the anchor is the glyph
                // before it; a row holding only the newline anchors at the
                // row start.
                let lastTextGlyph = fragmentEnd - 2
                let anchorX: CGFloat
                if lastTextGlyph >= glyphRange.location {
                    anchorX = layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: lastTextGlyph, length: 1),
                        in: container
                    ).maxX
                } else {
                    anchorX = 0
                }
                keptLayers.append(
                    paragraphMarker("\u{00B6}", afterLastGlyphAt: anchorX, in: fragment)
                )
            }
            glyph = fragmentEnd
        }

        markerLayers.forEach {
            if $0.superlayer != nil { $0.removeFromSuperlayer() }
        }
        markerLayers = keptLayers
        keptLayers.forEach {
            if $0.superlayer == nil { layer?.addSublayer($0) }
        }
    }

    /// Glyph index back to character index, linear from a cached start:
    /// glyph ranges are monotonically increasing, so the walk never
    /// restarts per fragment.
    private func mappedCharIndex(ofGlyph target: Int, in string: NSString, layoutManager: NSLayoutManager) -> Int {
        var char = 0
        while char < string.length {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: char, length: 1),
                actualCharacterRange: nil
            )
            if glyphRange.length > 0 && glyphRange.location >= target { return char }
            char += 1
        }
        return string.length
    }

    private func markerLayer(_ symbol: String, endOfRow fragment: CGRect, container: NSTextContainer) -> CATextLayer {
        let layer = markerLayerBase()
        layer.string = symbol
        let origin = textContainerOrigin
        layer.frame = CGRect(
            x: origin.x + fragment.maxX + container.lineFragmentPadding - markerWidth,
            y: origin.y + fragment.minY,
            width: markerWidth,
            height: fragment.height
        )
        layer.alignmentMode = .right
        return layer
    }

    private func paragraphMarker(_ symbol: String, afterLastGlyphAt lastGlyphMaxX: CGFloat, in fragment: CGRect) -> CATextLayer {
        let layer = markerLayerBase()
        layer.string = symbol
        let origin = textContainerOrigin
        layer.frame = CGRect(
            x: origin.x + lastGlyphMaxX + 2,
            y: origin.y + fragment.minY,
            width: markerWidth,
            height: fragment.height
        )
        layer.alignmentMode = .left
        return layer
    }

    private let markerWidth: CGFloat = 12

    private func markerLayerBase() -> CATextLayer {
        let layer = CATextLayer()
        layer.font = CTFontCreateWithName("Menlo" as CFString, 9, nil)
        layer.fontSize = 9
        layer.foregroundColor = NSColor.systemGray.withAlphaComponent(0.55).cgColor
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        return layer
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            scrollRangeToVisible(
                NSRange(location: selectedRange().location, length: 0)
            )
        }
        return ok
    }

    /// Return handling is done in keyDown, not doCommandBy: AppKit
    /// routes Shift+Return and Option+Return to different selectors
    /// depending on the key-binding dictionary, so the only reliable
    /// place to split send vs newline is the raw key event. Marked text
    /// (IME composition) must fall through so Return confirms the
    /// composition instead of sending.
    override func keyDown(with event: NSEvent) {
        // 36 is Return, 76 is the keypad Enter; both send.
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            let mods = event.modifierFlags
            if mods.contains(.command) {
                super.keyDown(with: event)
            } else if mods.intersection([.shift, .option, .control]).isEmpty {
                onReturn?()
            } else {
                insertText("\n", replacementRange: selectedRange())
            }
        } else {
            super.keyDown(with: event)
        }
    }

    /// Paste path: images and file URLs go to staging, everything else
    /// falls back to the default text paste.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        let types = board.types ?? []
        let hasImage = types.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true })
        let hasFileURL = types.contains(.fileURL)
        if hasImage || hasFileURL {
            onPaste?(board)
        } else {
            super.paste(sender)
        }
    }
}