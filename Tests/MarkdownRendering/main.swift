import AppKit
import Foundation
import SwiftUI
#if canImport(BusinessBar)
@testable import BusinessBar
#if BUSINESSBAR_COVERAGE_NATIVE
CoverageRuntimeIsolation.verify()
#endif
#endif

let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + 10)
watchdog.setEventHandler {
    fputs("FAIL: markdown rendering did not finish within 10 seconds\n", stderr)
    exit(1)
}
watchdog.resume()

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var checks = 0

func expectText(_ markdown: String, _ expected: String) {
    let rendered = MarkdownAttributedStringLoader.attributedString(for: markdown)
    guard rendered.string == expected else {
        fputs("FAIL: \(markdown.debugDescription) rendered as \(rendered.string.debugDescription), expected \(expected.debugDescription)\n", stderr)
        exit(1)
    }
    checks += 1
}

for literal in [
    "Hello!", "*unfinished", "**unfinished", "_unfinished", "__unfinished",
    "`unfinished", "~unfinished", "~~unfinished", "[label](", "![alt](",
    "snake_case_identifier", "trailing*", "trailing_", "trailing`",
    "trailing~", "trailing[", "trailing!", "🙂 [", ""
] {
    expectText(literal, literal.isEmpty ? "" : literal + "\n")
}

expectText("`code`", "code\n")
expectText("a\\*", "a*\n")
expectText("[link](https://example.com)", "link\n")
expectText("First paragraph!\n\nSecond paragraph!", "First paragraph!\n\nSecond paragraph!\n")

func expectStyle(_ markdown: String, text: String, span: String, bold: Bool, italic: Bool) {
    let rendered = MarkdownAttributedStringLoader.attributedString(for: markdown)
    guard rendered.string == text + "\n" else {
        fputs("FAIL: emphasis text \(markdown.debugDescription) rendered as \(rendered.string.debugDescription)\n", stderr)
        exit(1)
    }
    let range = (rendered.string as NSString).range(of: span)
    guard range.location != NSNotFound else {
        fputs("FAIL: emphasis span \(span.debugDescription) is missing\n", stderr)
        exit(1)
    }
    rendered.enumerateAttributes(in: range) { attributes, _, _ in
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
        let traits = NSFontManager.shared.traits(of: font)
        let isBold = traits.contains(.boldFontMask)
        let obliqueness = (attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0
        let isItalic = traits.contains(.italicFontMask) || obliqueness != 0
        guard isBold == bold, isItalic == italic else {
            fputs("FAIL: wrong emphasis for \(span.debugDescription) in \(markdown.debugDescription): bold=\(isBold), italic=\(isItalic)\n", stderr)
            exit(1)
        }
    }
    checks += 1
}

expectStyle("**bold**", text: "bold", span: "bold", bold: true, italic: false)
expectStyle("*italic*", text: "italic", span: "italic", bold: false, italic: true)
expectStyle("***both***", text: "both", span: "both", bold: true, italic: true)
expectStyle("Before *italic* and **bold** after.", text: "Before italic and bold after.", span: "Before", bold: false, italic: false)
expectStyle("Before *italic* and **bold** after.", text: "Before italic and bold after.", span: "italic", bold: false, italic: true)
expectStyle("Before *italic* and **bold** after.", text: "Before italic and bold after.", span: "bold", bold: true, italic: false)
expectStyle("Before *italic* and **bold** after.", text: "Before italic and bold after.", span: "after", bold: false, italic: false)
expectStyle("**bold *both***", text: "bold both", span: "both", bold: true, italic: true)
expectStyle("*italic **both***", text: "italic both", span: "both", bold: true, italic: true)
expectStyle("*unfinished", text: "*unfinished", span: "unfinished", bold: false, italic: false)
expectStyle("**unfinished", text: "**unfinished", span: "unfinished", bold: false, italic: false)
expectStyle("**bold *italic* bold**", text: "bold italic bold", span: "bold", bold: true, italic: false)
expectStyle("**bold *italic* bold**", text: "bold italic bold", span: "italic", bold: true, italic: true)
expectStyle("*italic **bold** italic*", text: "italic bold italic", span: "italic", bold: false, italic: true)
expectStyle("*italic **bold** italic*", text: "italic bold italic", span: "bold", bold: true, italic: true)
expectStyle("🙂 prefix **bold** tail", text: "🙂 prefix bold tail", span: "🙂 prefix", bold: false, italic: false)
expectStyle("🙂 prefix **bold** tail", text: "🙂 prefix bold tail", span: "bold", bold: true, italic: false)
expectStyle("__bold__ and _italic_", text: "bold and italic", span: "bold", bold: true, italic: false)
expectStyle("__bold__ and _italic_", text: "bold and italic", span: "italic", bold: false, italic: true)
expectStyle("snake_case_identifier", text: "snake_case_identifier", span: "snake_case_identifier", bold: false, italic: false)
expectStyle("Before * padded * after", text: "Before * padded * after", span: "padded", bold: false, italic: false)
expectStyle("Before \\*literal\\* after", text: "Before *literal* after", span: "literal", bold: false, italic: false)
expectStyle("Before `**literal**` after", text: "Before **literal** after", span: "literal", bold: false, italic: false)
expectStyle("Before *unfinished", text: "Before *unfinished", span: "unfinished", bold: false, italic: false)
expectStyle("Before **unfinished", text: "Before **unfinished", span: "unfinished", bold: false, italic: false)
expectStyle("Before [*link*](https://example.com) after", text: "Before link after", span: "link", bold: false, italic: true)

func expectAttribute(
    _ markdown: String,
    span: String,
    key: NSAttributedString.Key,
    baseURL: URL? = nil,
    matches: (Any?) -> Bool
) {
    let rendered = MarkdownAttributedStringLoader.attributedString(for: markdown, baseURL: baseURL)
    let range = (rendered.string as NSString).range(of: span)
    guard range.location != NSNotFound else {
        fputs("FAIL: attribute span \(span.debugDescription) is missing in \(rendered.string.debugDescription)\n", stderr)
        exit(1)
    }
    rendered.enumerateAttribute(key, in: range) { value, _, _ in
        guard matches(value) else {
            fputs("FAIL: wrong \(key.rawValue) for \(span.debugDescription) in \(markdown.debugDescription)\n", stderr)
            exit(1)
        }
    }
    checks += 1
}

expectAttribute("Before [*link*](https://example.com) after", span: "link", key: .link) {
    ($0 as? URL)?.absoluteString == "https://example.com"
}
expectAttribute("Before [link](https://example.com) after", span: "Before", key: .link) { $0 == nil }
expectAttribute("Before [link](https://example.com) after", span: "after", key: .link) { $0 == nil }
expectAttribute("[guide](guide)", span: "guide", key: .link, baseURL: URL(string: "https://example.com/docs/")) {
    ($0 as? URL)?.absoluteString == "https://example.com/docs/guide"
}
for url in ["http://example.com", "mailto:test@example.com", "tel:+123456789"] {
    expectAttribute("[link](\(url))", span: "link", key: .link) { ($0 as? URL)?.absoluteString == url }
}
for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/plain,test"] {
    expectText("Before [*unsafe* link](\(url)) after", "Before unsafe link (\(url)) after\n")
    expectAttribute("Before [*unsafe* link](\(url)) after", span: "unsafe link", key: .link) { $0 == nil }
}
expectText("Before ~~strike~~ after", "Before strike after\n")
expectAttribute("Before ~~strike~~ after", span: "strike", key: .strikethroughStyle) {
    ($0 as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue
}
expectAttribute("Before ~~strike~~ after", span: "after", key: .strikethroughStyle) { $0 == nil }
expectAttribute("Before `**literal**` after", span: "**literal**", key: .font) {
    ($0 as? NSFont)?.isFixedPitch == true
}
expectAttribute("# *Heading*", span: "Heading", key: .font) { ($0 as? NSFont)?.pointSize == 17.5 }
expectText("Before ![alt **text**](https://example.com/a.png) after", "Before [image: alt text] after\n")
expectText("![](https://example.com/a.png)", "[image]\n")
expectText("![a](https://example.com/a.png)![b](https://example.com/a.png)", "[image: a][image: b]\n")
expectAttribute("![alt](https://example.com/a.png)", span: "[image: alt]", key: .imageURL) { $0 == nil }
expectAttribute("![alt](https://example.com/a.png)", span: "[image: alt]", key: .attachment) { $0 == nil }
expectText("[![alt](https://example.com/a.png)](https://example.com)", "[image: alt]\n")
for key in [NSAttributedString.Key.link, .attachment, .imageURL] {
    expectAttribute("[![alt](https://example.com/a.png)](https://example.com)", span: "[image: alt]", key: key) { $0 == nil }
}
expectText("Before `**literal**` after\n\n```\n*still literal*\n```", "Before **literal** after\n\n*still literal*\n")

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    checks += 1
}

struct TableCell {
    let range: NSRange
    let block: NSTextTableBlock
    let style: NSParagraphStyle
    let text: String
}

func tableCells(_ rendered: NSAttributedString) -> [TableCell] {
    let string = rendered.string as NSString
    var cells: [TableCell] = []
    var offset = 0
    while offset < string.length {
        let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
        if let style = rendered.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle,
           let block = style.textBlocks.last as? NSTextTableBlock {
            cells.append(TableCell(range: range, block: block, style: style, text: string.substring(with: range)))
        }
        offset = NSMaxRange(range)
    }
    return cells
}

let tableReply = "Before table.\n\n| Left | Right | Center |\n| :--- | ---: | :---: |\n| alpha | beta | gamma |\n| delta | epsilon | zeta |\n\nAfter table."
let tableRendered = MarkdownAttributedStringLoader.attributedString(for: tableReply)
let basicCells = tableCells(tableRendered)
require(basicCells.count == 9, "top-level table must have nine native cells, got \(basicCells.count)")
for (index, cell) in basicCells.enumerated() {
    require(cell.block.startingRow == index / 3 && cell.block.startingColumn == index % 3,
            "native table coordinates differ at cell \(index)")
    require(cell.text.hasSuffix("\n"), "table cell \(index) lacks its styled newline")
    let newlineStyle = tableRendered.attribute(.paragraphStyle, at: NSMaxRange(cell.range) - 1, effectiveRange: nil) as? NSParagraphStyle
    require(newlineStyle?.textBlocks.last === cell.block, "cell newline lost its native block")
    require(cell.style.alignment == [NSTextAlignment.left, .right, .center][index % 3], "table alignment differs at cell \(index)")
    require(cell.block.table === basicCells[0].block.table, "cells do not share one native table")
}
for prose in ["Before table.", "After table."] {
    let range = (tableRendered.string as NSString).range(of: prose)
    require(range.location != NSNotFound, "surrounding prose disappeared")
    let style = tableRendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    require(style?.textBlocks.isEmpty != false, "surrounding prose inherited table paragraph style")
}

let styledTable = "| *Italic* | `code` | [*safe*](https://example.com) |\n| --- | --- | --- |\n| [bad](javascript:alert(1)) | ![alt](https://example.com/a.png) | **body** |"
let styledCells = tableCells(MarkdownAttributedStringLoader.attributedString(for: styledTable))
require(styledCells.count == 6, "styled table lost cells")
for span in ["Italic", "code", "safe"] {
    expectAttribute(styledTable, span: span, key: .font) {
        guard let font = $0 as? NSFont else { return false }
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }
}
expectAttribute(styledTable, span: "Italic", key: .obliqueness) { (($0 as? NSNumber)?.doubleValue ?? 0) != 0 }
expectAttribute(styledTable, span: "safe", key: .obliqueness) { (($0 as? NSNumber)?.doubleValue ?? 0) != 0 }
expectAttribute(styledTable, span: "code", key: .font) { ($0 as? NSFont)?.isFixedPitch == true }
expectAttribute(styledTable, span: "safe", key: .link) { ($0 as? URL)?.absoluteString == "https://example.com" }
expectAttribute(styledTable, span: "bad", key: .link) { $0 == nil }
for key in [NSAttributedString.Key.link, .attachment, .imageURL] {
    expectAttribute(styledTable, span: "[image: alt]", key: key) { $0 == nil }
}
require(MarkdownAttributedStringLoader.attributedString(for: styledTable).string.contains("bad (javascript:alert(1))"), "rejected table link lost readable target")

for (markdown, expected) in [
    ("| A | B |\n| --- | --- |\n| a\\|b | `c\\|d` |", ["A\n", "B\n", "a|b\n", "c|d\n"]),
    ("A | B\n--- | ---\nx | y", ["A\n", "B\n", "x\n", "y\n"]),
    ("| A | B |\n| --- | --- |\n| one |\n| two | three | ignored |\n| | |", ["A\n", "B\n", "one\n", "\n", "two\n", "three\n", "\n", "\n"])
] {
    let rendered = MarkdownAttributedStringLoader.attributedString(for: markdown)
    let cells = tableCells(rendered)
    require(cells.map(\.text) == expected, "escaped, padded, truncated or empty cells differ: \(cells.map(\.text))")
    for (index, cell) in cells.enumerated() {
        require(cell.block.startingRow == index / 2 && cell.block.startingColumn == index % 2, "edge-case cell coordinate differs")
        let style = rendered.attribute(.paragraphStyle, at: NSMaxRange(cell.range) - 1, effectiveRange: nil) as? NSParagraphStyle
        require(cell.text.hasSuffix("\n") && style?.textBlocks.last === cell.block, "edge-case cell lost styled newline")
    }
}
for markdown in ["| | |\n| --- | --- |", "| A | B |\n| --- | --- |"] {
    let cells = tableCells(MarkdownAttributedStringLoader.attributedString(for: markdown))
    require(cells.count == 2 && cells.allSatisfy { $0.text.hasSuffix("\n") }, "header-only table lost native cells")
}
for markdown in ["| A | B |\n| -x- | --- |", "| A | B |\n| --- |", "| A | B |\n| :", "```\n| A | B |\n| --- | --- |\n| x | y |\n```"] {
    let rendered = MarkdownAttributedStringLoader.attributedString(for: markdown)
    require(tableCells(rendered).isEmpty, "invalid delimiter or fenced code became a native table")
    require(rendered.string.contains("| A | B |"), "non-table source is no longer readable")
}

let streamedReplies = [
    "Hello! A *partial emphasis*, **bold**, ~~strike~~ and `code`.",
    "A [link](https://example.com) and ![image](https://example.com/a.png).",
    "## Heading\n\nFirst paragraph!\n\n- One\n- Two\n\n```swift\nlet value = 1\n```",
    "snake_case_identifier with trailing punctuation: [!_*~` 🙂",
    "Before *italic* and **bold** after.",
    "**bold *italic* bold** and *italic **bold** italic*"
]
for reply in streamedReplies {
    for end in reply.indices {
        _ = MarkdownAttributedStringLoader.attributedString(for: String(reply[..<end]))
        checks += 1
    }
    _ = MarkdownAttributedStringLoader.attributedString(for: reply)
    checks += 1
}

for length in [1, 2, 8, 32, 128, 512] {
    _ = MarkdownAttributedStringLoader.attributedString(for: String(repeating: "!", count: length))
    checks += 1
}

func findTextView(in view: NSView) -> MarkdownTextView? {
    if let textView = view as? MarkdownTextView { return textView }
    return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
}

struct MarkdownBubbleFixture: View {
    let markdown: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer(minLength: 40)
                    Text("Test prompt").padding(10)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        MarkdownTextHostingView(markdown: markdown)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("Copy").font(.caption)
                    }
                    Spacer(minLength: 40)
                }
            }
            .padding()
        }
    }
}

let hostingView = NSHostingView(rootView: MarkdownBubbleFixture(markdown: ""))
let coldMarkdown = "## Cold heading\n\nBefore table.\n\n| A | B |\n| --- | --- |\n| one | two |\n\nAfter table."
let coldHostingView = NSHostingView(rootView: MarkdownBubbleFixture(markdown: coldMarkdown))
let coldWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
coldWindow.isReleasedWhenClosed = false
coldWindow.contentView = coldHostingView
coldHostingView.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
coldHostingView.layoutSubtreeIfNeeded()
if let text = findTextView(in: coldHostingView), let wrapper = text.superview,
   let layout = text.layoutManager, let container = text.textContainer {
    layout.ensureLayout(for: container)
    let glyphs = layout.usedRect(for: container).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    let allocation = text.convert(wrapper.bounds, from: wrapper)
    require(allocation.insetBy(dx: -0.5, dy: -0.5).contains(glyphs), "cold nonempty native host clips glyphs: frame \(text.frame), allocation \(allocation), glyphs \(glyphs)")
    require(abs(text.frame.minY - wrapper.bounds.minY) <= 0.5, "cold native text view is displaced from its wrapper origin")
    require(tableCells(text.attributedString()).count == 4, "cold nonempty host lost native table cells")
} else {
    require(false, "cold nonempty native host has no text layout")
}
coldWindow.close()
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.isReleasedWhenClosed = false
window.contentView = hostingView

var heartbeats = 0
let heartbeat = Timer(timeInterval: 0.002, repeats: true) { _ in heartbeats += 1 }
RunLoop.main.add(heartbeat, forMode: .common)

@discardableResult
func renderNative(_ markdown: String, expected: String? = nil) -> MarkdownTextView {
    hostingView.rootView = MarkdownBubbleFixture(markdown: markdown)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    guard let textView = findTextView(in: hostingView),
          textView.markdownTag == markdown else {
        fputs("FAIL: native text view did not receive its markdown update\n", stderr)
        exit(1)
    }
    if let expected, textView.string != expected {
        fputs("FAIL: native text storage differs from the expected reply\n", stderr)
        exit(1)
    }
    if !textView.string.isEmpty {
        guard let layout = textView.layoutManager,
              let container = textView.textContainer,
              let wrapper = textView.superview else {
            fputs("FAIL: native reply has no text layout\n", stderr)
            exit(1)
        }
        layout.ensureLayout(for: container)
        let textBounds = layout.usedRect(for: container).offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
        let allocatedBounds = textView.convert(wrapper.bounds, from: wrapper)
        guard textBounds.height > 0,
              allocatedBounds.insetBy(dx: -0.5, dy: -0.5).contains(textBounds) else {
            fputs("FAIL: chat bubble clips reply glyphs: \(markdown.count) characters at \(window.contentLayoutRect.size), text \(textBounds), allocated \(allocatedBounds)\n", stderr)
            exit(1)
        }
    }
    checks += 1
    return textView
}

let nativeReply = "Hello! [unfinished"
for end in nativeReply.indices {
    renderNative(String(nativeReply[..<end]))
}
let emphasizedView = renderNative("Before *italic* and **bold** after.", expected: "Before italic and bold after.\n")
let italicRange = (emphasizedView.string as NSString).range(of: "italic")
let boldRange = (emphasizedView.string as NSString).range(of: "bold")
guard let storage = emphasizedView.textStorage,
      let italic = storage.attribute(.obliqueness, at: italicRange.location, effectiveRange: nil) as? NSNumber,
      italic.doubleValue != 0,
      let boldFont = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont,
      NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask) else {
    fputs("FAIL: native text storage lost italic or bold styling\n", stderr)
    exit(1)
}
checks += 1
renderNative("First paragraph!\n\nSecond paragraph!", expected: "First paragraph!\n\nSecond paragraph!\n")
if let textView = findTextView(in: hostingView) {
    let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13))
    guard textView.frame.width > 0, textView.frame.height >= lineHeight * 3 else {
        fputs("FAIL: chat text view clips its paragraphs at frame \(textView.frame)\n", stderr)
        exit(1)
    }
    checks += 1
    textView.selectAll(nil)
    guard textView.selectedRange() == NSRange(location: 0, length: textView.textStorage?.length ?? 0) else {
        fputs("FAIL: native select-all did not include both paragraphs\n", stderr)
        exit(1)
    }
    checks += 1
}

let wrappedReply = String(repeating: "Wrapped reply text. ", count: 12) + "\n\nLast paragraph!"
func glyphBounds(_ range: NSRange, in textView: MarkdownTextView) -> NSRect {
    guard let layout = textView.layoutManager, let container = textView.textContainer else {
        require(false, "table has no native glyph layout")
        return .zero
    }
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    return layout.boundingRect(forGlyphRange: glyphs, in: container)
}

func verifyNativeTable(_ textView: MarkdownTextView) {
    guard let storage = textView.textStorage else {
        require(false, "table native storage is absent")
        return
    }
    let cells = tableCells(storage)
    require(cells.count == 9, "integrated native table lost rows or cells")
    let bounds = cells.map { glyphBounds($0.range, in: textView) }
    for (index, rect) in bounds.enumerated() {
        require(rect.width > 0 && rect.height > 0, "cell \(index) has no visible glyph allocation")
    }
    for row in 0..<3 {
        let first = bounds[row * 3]
        let middle = bounds[row * 3 + 1]
        let last = bounds[row * 3 + 2]
        require(first.maxX <= middle.minX + 1 && middle.maxX <= last.minX + 1,
                "table row \(row) does not visibly occupy separate columns: \(first), \(middle), \(last)")
    }
    let after = (storage.string as NSString).range(of: "After table.")
    require(after.location != NSNotFound, "integrated table lost following prose")
    require(glyphBounds(after, in: textView).minY >= bounds.map(\.maxY).max()! - 1,
            "following prose overlaps the native table")
    textView.selectAll(nil)
    require(textView.selectedRange() == NSRange(location: 0, length: storage.length),
            "select-all excludes table or prose")
}

let narrowTable = "| A | B | C | D | E | F |\n| --- | --- | --- | --- | --- | --- |\n| `https://example.com/" + String(repeating: "unbreakable", count: 12) + "` | two | three | four | five | six |\n\nFollowing narrow table."
let tablePrefixes = [
    "| A | B |", "| A | B |\n|", "| A | B |\n| --- |",
    "| A | B |\n| --- | ---", "| A | B |\n| --- | --- |\n|",
    "| A | B |\n| --- | --- |\n| body", "| A | B |\n| --- | --- |\n| body | `partial",
    "| A | B |\n| --- | --- |\n| body | complete |"
]
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    window.appearance = NSAppearance(named: appearance)
    var heights: [CGFloat] = []
    var tableHeights: [CGFloat] = []
    for width: CGFloat in [300, 480, 900] {
        window.setContentSize(NSSize(width: width, height: 900))
        let textView = renderNative(wrappedReply, expected: wrappedReply + "\n")
        heights.append(textView.frame.height)
        verifyNativeTable(renderNative(tableReply, expected: tableRendered.string))
        let narrow = renderNative(narrowTable)
        let narrowCells = tableCells(narrow.attributedString())
        require(narrowCells.count == 12, "many-column table lost native cells")
        tableHeights.append(narrow.frame.height)
        for cell in narrowCells {
            let rect = glyphBounds(cell.range, in: narrow)
            require(rect.minX >= -0.5 && rect.maxX <= (narrow.textContainer?.containerSize.width ?? 0) + 0.5,
                    "narrow table cell glyphs escape container: \(rect)")
        }
    }
    guard heights[0] > heights[2] else {
        fputs("FAIL: chat reply height did not follow narrower wrapping widths: \(heights)\n", stderr)
        exit(1)
    }
    checks += 1
    require(tableHeights[0] > tableHeights[2], "long unbreakable table code does not wrap on resize: \(tableHeights)")
    let shortReply = renderNative("Short!", expected: "Short!\n")
    let shortHeight = shortReply.frame.height
    guard shortHeight < heights[2] else {
        fputs("FAIL: chat reply height did not shrink after a shorter update\n", stderr)
        exit(1)
    }
    checks += 1
    renderNative("", expected: "")
    verifyNativeTable(renderNative(tableReply, expected: tableRendered.string))
    renderNative("", expected: "")
    for prefix in tablePrefixes {
        let streamed = renderNative(prefix)
        require(streamed.string.contains("A") && streamed.string.contains("B"), "streaming table prefix lost readable header")
        if prefix.contains("body") {
            require(streamed.string.contains("body"), "streaming table prefix lost body text")
        }
    }
    let restored = renderNative(wrappedReply, expected: wrappedReply + "\n")
    guard restored.frame.height > shortHeight else {
        fputs("FAIL: chat reply height did not grow after an empty update\n", stderr)
        exit(1)
    }
    checks += 1
    renderNative(streamedReplies[2])
}
let overflowingReply = renderNative(String(repeating: "A long reply paragraph!\n\n", count: 40))
guard overflowingReply.frame.height > window.contentLayoutRect.height else {
    fputs("FAIL: long reply did not retain its full height beyond the scroll viewport\n", stderr)
    exit(1)
}
checks += 1
window.appearance = nil
window.setContentSize(NSSize(width: 480, height: 360))

if let option = CommandLine.arguments.firstIndex(of: "--stream-chunks") {
    guard option + 1 < CommandLine.arguments.count else {
        fputs("FAIL: --stream-chunks requires a recorded stream JSON path\n", stderr)
        exit(1)
    }
    struct RecordedStream: Decodable {
        let chunks: [String]
        let fullText: String
        let terminal: String
    }
    let stream: RecordedStream
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[option + 1]))
        stream = try JSONDecoder().decode(RecordedStream.self, from: data)
    } catch {
        fputs("FAIL: cannot read the recorded stream JSON: \(error)\n", stderr)
        exit(1)
    }
    guard stream.terminal == "finished", !stream.chunks.isEmpty else {
        fputs("FAIL: local-model stream did not finish with text chunks\n", stderr)
        exit(1)
    }
    var reply = ""
    for chunk in stream.chunks {
        reply += chunk
        renderNative(reply)
    }
    guard reply == stream.fullText else {
        fputs("FAIL: streamed deltas differ from the finished reply\n", stderr)
        exit(1)
    }
    checks += 1
    print("PASS: \(stream.chunks.count) real local-model chunks rendered through the native hosting view")
}

heartbeat.invalidate()
window.close()
guard heartbeats > 0 else {
    fputs("FAIL: main run loop did not advance during native rendering\n", stderr)
    exit(1)
}
checks += 1
watchdog.cancel()
print("PASS: \(checks) markdown rendering checks")
