import AppKit
import Foundation
import SwiftUI

// MARK: - MarkdownTextLayout

/// Layout constants shared by the loader and the hosting view.
private enum MarkdownTextLayout {
    /// Extra space above/below block-level elements (headings, lists,
    /// code fences), matching the rhythm of the old MarkdownUI theme.
    static let blockSpacing: CGFloat = 6
}

// MARK: - MarkdownAttributedStringLoader

/// Parses a markdown reply into one NSAttributedString so the chat can
/// host it in a single NSTextView. Selection then spans every paragraph of
/// the reply, which the SwiftUI Text stack cannot offer (each markdown
/// block becomes its own Text and macOS selection never crosses Text
/// views).
///
/// Rendering covers the shapes models actually produce in chat: headings,
/// paragraphs with inline styles (bold, italic, strikethrough, inline
/// code, links), bullet and numbered lists, nested quotes, fenced code
/// blocks, and thematic breaks. Images stay unparsed as their alt text
/// since assistant replies rarely embed them; the raw markdown remains
/// one Copy button away.
enum MarkdownAttributedStringLoader {

    // MARK: Block model

    private enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case codeBlock(language: String?, content: String, openFence: String?)
        case quote(lines: [String])
        case list(items: [String])
        case thematicBreak
    }

    private struct ListContext {
        /// Ordered-list counter shared across consecutive numbered lists.
        var number = 0
    }

    // MARK: Public API

    /// One attributed string for the whole reply.
    static func attributedString(for markdown: String, baseURL: URL? = nil) -> NSAttributedString {
        let blocks = parseBlocks(markdown)
        let attributed = NSMutableAttributedString()
        var listContext = ListContext()
        for (index, block) in blocks.enumerated() {
            if index > 0 { attributed.append(newline()) }
            render(block: block, into: attributed, baseURL: baseURL, listContext: &listContext)
        }
        return attributed
    }

    // MARK: Parsing

    private static func parseBlocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var listLines: [String] = []
        var fence: String?
        var fenceLines: [String] = []
        var fenceInfo: String?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(lines: quoteLines))
            quoteLines.removeAll()
        }
        func flushList() {
            guard !listLines.isEmpty else { return }
            blocks.append(.list(items: listLines))
            listLines.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let open = fence {
                if lineHasFenceEnd(line, open: open) {
                    blocks.append(.codeBlock(
                        language: fenceInfo,
                        content: fenceLines.joined(separator: "\n"),
                        openFence: open
                    ))
                    fence = nil
                    fenceLines = []
                    fenceInfo = nil
                } else {
                    fenceLines.append(line)
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushAll()
                fence = line
                fenceInfo = Self.fenceLanguage(line)
                fenceLines = []
                continue
            }
            if isThematicBreak(line) {
                flushAll()
                blocks.append(.thematicBreak)
                continue
            }
            if let heading = parseHeading(line) {
                flushAll()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if isQuoteLine(line) {
                flushParagraph()
                flushList()
                quoteLines.append(stripQuoteMarker(line))
                continue
            }
            if isListLine(line) {
                flushParagraph()
                flushQuote()
                listLines.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushAll()
                continue
            }
            flushQuote()
            flushList()
            paragraphLines.append(line)
        }
        // An unterminated fence still renders as a code block; a fence
        // still empty at end-of-text renders nothing (no zero-length
        // block padding a phantom blank line).
        if fence != nil {
            if !fenceLines.isEmpty {
                blocks.append(.codeBlock(
                    language: fenceInfo,
                    content: fenceLines.joined(separator: "\n"),
                    openFence: fence
                ))
            }
        } else {
            flushAll()
        }
        return blocks
    }

    private static func fenceLanguage(_ fenceLine: String) -> String? {
        let info = fenceLine.drop { $0 == "`" || $0 == "~" || $0 == " " }
        return info.isEmpty ? nil : String(info)
    }

    private static func lineHasFenceEnd(_ line: String, open: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let openChar = open.hasPrefix("~~~") ? "~" : "`"
        guard trimmed.hasPrefix(String(repeating: openChar, count: 3)) else { return false }
        return trimmed.allSatisfy { $0 == openChar }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed == String(repeating: "-", count: trimmed.count)
            || trimmed == String(repeating: "*", count: trimmed.count)
            || trimmed == String(repeating: "_", count: trimmed.count)
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var rest = Substring(line)
        while rest.hasPrefix("#") {
            level += 1
            rest = rest.dropFirst()
        }
        guard level <= 6, rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.hasPrefix(">") || line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func stripQuoteMarker(_ line: String) -> String {
        guard let index = line.firstIndex(of: ">") else { return line }
        return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        // numbered: digits, optional dot or paren, then space
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let afterDigits = trimmed.dropFirst(digits.count)
        return afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ")
    }

    // MARK: Rendering

    private static func render(
        block: Block,
        into attributed: NSMutableAttributedString,
        baseURL: URL?,
        listContext: inout ListContext
    ) {
        switch block {
        case .paragraph(let text):
            appendInline(text, into: attributed, baseURL: baseURL)
            appendBlockSpacing(attributed)
        case .heading(let level, let text):
            appendHeading(level: level, text: text, into: attributed, baseURL: baseURL)
            appendBlockSpacing(attributed)
        case .codeBlock(let language, let content, let openFence):
            appendCodeBlock(language: language, content: content, openFence: openFence, into: attributed)
            appendBlockSpacing(attributed)
        case .quote(let lines):
            appendQuote(lines: lines, into: attributed, baseURL: baseURL)
            appendBlockSpacing(attributed)
        case .list(let items):
            appendList(items: items, into: attributed, baseURL: baseURL, listContext: &listContext)
            appendBlockSpacing(attributed)
        case .thematicBreak:
            appendThematicBreak(into: attributed)
            appendBlockSpacing(attributed)
        }
    }

    private static func newline() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: baseAttributes())
    }

    private static func appendBlockSpacing(_ attributed: NSMutableAttributedString) {
        attributed.append(newline())
    }

    /// Base attributes: system label color, body font size 13 matching
    /// the composer size, and the scheme gate applied to links.
    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
    }

    private static func appendHeading(
        level: Int,
        text: String,
        into attributed: NSMutableAttributedString,
        baseURL: URL?
    ) {
        let sizes: [Int: CGFloat] = [1: 17.5, 2: 15.5, 3: 14, 4: 13, 5: 13, 6: 13]
        let size = sizes[level] ?? 13
        var attrs = baseAttributes()
        attrs[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
        if level <= 3 {
            let paragraph = (attrs[.paragraphStyle] as? NSMutableParagraphStyle ?? NSMutableParagraphStyle())
            paragraph.paragraphSpacingBefore = MarkdownTextLayout.blockSpacing
            attrs[.paragraphStyle] = paragraph
        }
        appendInline(text, into: attributed, baseURL: baseURL, extraAttributes: attrs)
    }

    private static func appendCodeBlock(
        language: String?,
        content: String,
        openFence: String?,
        into attributed: NSMutableAttributedString
    ) {
        let code = NSMutableAttributedString(string: content, attributes: codeAttributes())
        // Mark the block bounds so the hosting view can find the fences
        // for line numbers and copy actions.
        code.addAttribute(
            .markdownCodeBlock,
            value: NSString(string: openFence ?? "```"),
            range: NSRange(location: 0, length: code.length)
        )
        attributed.append(code)
    }

    private static func codeAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 1
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: paragraph,
            .markdownCodeBlock: NSString(string: "```")
        ]
    }

    private static func appendQuote(
        lines: [String],
        into attributed: NSMutableAttributedString,
        baseURL: URL?
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.headIndent = 16
        paragraph.firstLineHeadIndent = 16
        paragraph.paragraphSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        for (index, line) in lines.enumerated() {
            if index > 0 { attributed.append(NSAttributedString(string: "\n", attributes: attrs)) }
            appendInline(line, into: attributed, baseURL: baseURL, extraAttributes: attrs)
        }
    }

    private static func appendList(
        items: [String],
        into attributed: NSMutableAttributedString,
        baseURL: URL?,
        listContext: inout ListContext
    ) {
        let numbered = items.first.map(isNumberedListStart) ?? false
        var index = 0
        for item in items {
            let marker: String
            if numbered {
                listContext.number += 1
                marker = "\(listContext.number). "
            } else {
                marker = "• "
            }
            attributed.append(NSAttributedString(string: marker, attributes: listMarkerAttributes()))
            let itemText = stripListMarker(item)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.headIndent = 14
            paragraph.firstLineHeadIndent = 0
            paragraph.paragraphSpacing = 2
            appendInline(itemText, into: attributed, baseURL: baseURL, extraAttributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
            index += 1
            if index < items.count {
                attributed.append(NSAttributedString(string: "\n", attributes: listMarkerAttributes()))
            }
        }
    }

    private static func listMarkerAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.headIndent = 14
        paragraph.firstLineHeadIndent = 0
        paragraph.paragraphSpacing = 2
        return [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
    }

    private static func isNumberedListStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let after = trimmed.dropFirst(digits.count)
        return after.hasPrefix(". ") || after.hasPrefix(") ")
    }

    private static func stripListMarker(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: " ") {
            let prefix = String(trimmed[..<range.lowerBound])
            if prefix.hasSuffix(".") || prefix.hasSuffix(")") || prefix == "-" || prefix == "*" || prefix == "+" {
                return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }

    private static func appendThematicBreak(into attributed: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.separatorColor,
            .paragraphStyle: paragraph
        ]
        attributed.append(NSAttributedString(string: "―――", attributes: attrs))
    }

    // MARK: Inline rendering

    /// Renders inline markdown (bold, italic, strikethrough, inline code,
    /// links, bare URLs) into `attributed`. Images render as alt text
    /// since assistant replies rarely embed them.
    private static func appendInline(
        _ text: String,
        into attributed: NSMutableAttributedString,
        baseURL: URL?,
        extraAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        var remaining = Substring(text)
        while !remaining.isEmpty {
            // link: [label](url)
            if let (label, url, after) = parseLink(remaining) {
                appendLink(label: label, url: url, into: attributed, baseURL: baseURL, extraAttributes: extraAttributes)
                remaining = after
                continue
            }
            // image: ![alt](src) -> alt text
            if let (alt, _, after) = parseImage(remaining) {
                appendInline(alt.isEmpty ? " [image] " : " [image: \(alt)] ", into: attributed, baseURL: baseURL, extraAttributes: extraAttributes)
                remaining = after
                continue
            }
            // bold: **text** or __text__
            if let (inner, after) = parseDelimited(remaining, marker: "**") ?? parseDelimited(remaining, marker: "__") {
                appendEmphasized(inner: inner, weight: .bold, into: attributed, baseURL: baseURL, extraAttributes: extraAttributes)
                remaining = after
                continue
            }
            // italic: *text* anywhere; _text_ only at word boundaries
            // (snake_case_identifiers must not italicize)
            if let (inner, after) = parseDelimited(remaining, marker: "*") {
                appendEmphasized(inner: inner, obliqueness: 0.2, into: attributed, baseURL: baseURL, extraAttributes: extraAttributes)
                remaining = after
                continue
            }
            if let (inner, after) = parseDelimitedWordBoundary(remaining, marker: "_") {
                appendEmphasized(inner: inner, obliqueness: 0.2, into: attributed, baseURL: baseURL, extraAttributes: extraAttributes)
                remaining = after
                continue
            }
            // strikethrough: ~~text~~
            if let (inner, after) = parseDelimited(remaining, marker: "~~") {
                appendEmphasized(inner: inner, strikethroughStyle: NSUnderlineStyle.single.rawValue, into: attributed, baseURL: baseURL, extraAttributes: extraAttributes)
                remaining = after
                continue
            }
            // inline code: `code`
            if let (inner, after) = parseDelimited(remaining, marker: "`") {
                appendCodeSpan(inner, into: attributed, extraAttributes: extraAttributes)
                remaining = after
                continue
            }
            // plain run up to the next marker
            let next = nextMarkerIndex(remaining)
            let run = remaining[..<next]
            appendPlain(String(run), into: attributed, extraAttributes: extraAttributes)
            remaining = remaining[next...]
        }
    }

    private static func parseLink(_ text: Substring) -> (label: String, url: String, after: Substring)? {
        guard let bracket = findUnescaped(text, "[") else { return nil }
        guard let close = findMatchingBracket(text, from: bracket) else { return nil }
        guard let paren = findAfter(text, "(", after: close) else { return nil }
        guard let parenEnd = findMatchingParen(text, from: paren) else { return nil }
        let label = String(text[text.index(after: bracket)..<close])
        let url = String(text[text.index(after: paren)..<parenEnd])
        return (label, url, text[text.index(after: parenEnd)...])
    }

    private static func parseImage(_ text: Substring) -> (alt: String, source: String, after: Substring)? {
        guard let bang = findUnescaped(text, "![") else { return nil }
        guard let close = findMatchingBracket(text, from: text.index(after: bang)) else { return nil }
        guard let paren = findAfter(text, "(", after: close) else { return nil }
        guard let parenEnd = findMatchingParen(text, from: paren) else { return nil }
        let alt = String(text[text.index(after: bang)..<close])
        let source = String(text[text.index(after: paren)..<parenEnd])
        return (alt, source, text[text.index(after: parenEnd)...])
    }

    private static func parseDelimited(_ text: Substring, marker: String) -> (inner: String, after: Substring)? {
        guard let start = findUnescaped(text, marker) else { return nil }
        let contentStart = text.index(after: start)
        guard let end = findUnescaped(Substring(text[contentStart...]), marker) else { return nil }
        let inner = String(text[contentStart..<end])
        guard !inner.isEmpty else { return nil }
        return (inner, text[text.index(after: end)...])
    }

    /// Underscore emphasis needs word boundaries on both sides, per
    /// CommonMark: a_b_c stays literal, so mid-word underscores never
    /// start italic. The character before the opening marker and after
    /// the closing marker must be punctuation, space, or text edge.
    private static func parseDelimitedWordBoundary(_ text: Substring, marker: String) -> (inner: String, after: Substring)? {
        guard let start = findUnescaped(text, marker) else { return nil }
        // Left flanking: an alphanumeric before the opening marker means
        // mid-word underscore, CommonMark leaves it literal.
        if start > text.startIndex {
            let prevChar = text[text.index(before: start)]
            if prevChar.isLetter || prevChar.isNumber { return nil }
        }
        let contentStart = text.index(after: start)
        guard let end = findUnescaped(Substring(text[contentStart...]), marker) else { return nil }
        let inner = String(text[contentStart..<end])
        guard !inner.isEmpty else { return nil }
        // Right flanking: next char must not be alphanumeric
        let afterEnd = text.index(after: end)
        if afterEnd < text.endIndex {
            let nextChar = text[afterEnd]
            if nextChar.isLetter || nextChar.isNumber { return nil }
        }
        return (inner, text[afterEnd...])
    }

    private static func findUnescaped(_ text: Substring, _ needle: String) -> (Substring.Index)? {
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] != "\\" {
                return range.lowerBound
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func findMatchingBracket(_ text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            let ch = text[index]
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func findAfter(_ text: Substring, _ needle: String, after index: Substring.Index) -> Substring.Index? {
        text.range(of: needle, range: index..<text.endIndex)?.lowerBound
    }

    private static func findMatchingParen(_ text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            let ch = text[index]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func nextMarkerIndex(_ text: Substring) -> Substring.Index {
        let markers = ["[", "!", "`", "*", "_", "~"]
        var earliest: Substring.Index? = nil
        for marker in markers {
            if let range = text.range(of: marker) {
                if earliest == nil || range.lowerBound < earliest! {
                    earliest = range.lowerBound
                }
            }
        }
        return earliest ?? text.endIndex
    }

    private static func appendPlain(
        _ text: String,
        into attributed: NSMutableAttributedString,
        extraAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        var attrs = extraAttributes ?? baseAttributes()
        if extraAttributes == nil {
            attrs[.foregroundColor] = NSColor.labelColor
        }
        attributed.append(NSAttributedString(string: text, attributes: attrs))
    }

    private static func appendLink(
        label: String,
        url: String,
        into attributed: NSMutableAttributedString,
        baseURL: URL?,
        extraAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        var attrs = extraAttributes ?? baseAttributes()
        if let resolved = URL(string: url, relativeTo: baseURL),
           let scheme = resolved.scheme?.lowercased(),
           allowedLinkSchemes.contains(scheme) {
            attrs[.link] = resolved
            attrs[.foregroundColor] = NSColor.linkColor
        } else {
            attrs[.foregroundColor] = NSColor.labelColor
            // Inert schemes render as plain text with the raw URL next to
            // the label so nothing reads as clickable.
            attributed.append(NSAttributedString(string: label, attributes: attrs))
            attributed.append(NSAttributedString(string: " (\(url))", attributes: attrs))
            return
        }
        attributed.append(NSAttributedString(string: label, attributes: attrs))
    }

    private static func appendEmphasized(
        inner: String,
        weight: NSFont.Weight? = nil,
        obliqueness: Float? = nil,
        strikethroughStyle: Int? = nil,
        into attributed: NSMutableAttributedString,
        baseURL: URL?,
        extraAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        var attrs = extraAttributes ?? baseAttributes()
        if let weight {
            let baseFont = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
            attrs[.font] = NSFont.systemFont(ofSize: baseFont.pointSize, weight: weight)
        }
        if let obliqueness {
            attrs[.obliqueness] = obliqueness
        }
        if let strikethroughStyle {
            attrs[.strikethroughStyle] = strikethroughStyle
        }
        appendInline(inner, into: attributed, baseURL: baseURL, extraAttributes: attrs)
    }

    private static func appendCodeSpan(
        _ code: String,
        into attributed: NSMutableAttributedString,
        extraAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        var attrs = extraAttributes ?? baseAttributes()
        attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        attrs[.backgroundColor] = NSColor.controlBackgroundColor
        attributed.append(NSAttributedString(string: code, attributes: attrs))
    }
}

// MARK: - NSAttributedString keys

extension NSAttributedString.Key {
    /// Marks spans that belong to a fenced code block. Value: opening
    /// fence string (e.g. "```swift").
    static let markdownCodeBlock = NSAttributedString.Key("com.businessbar.markdownCodeBlock")
}