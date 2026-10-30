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

// MARK: - MarkdownTextLinkPolicy

/// Schemes a chat message may open; anything else (file, ssh, custom
/// handlers) coming from model output stays inert. Shared by the
/// attributed-string loader, the hosting view's click gate, and the
/// SwiftUI open-chat-link helper.
enum MarkdownTextLinkPolicy {
    static let schemes: Set<String> = ["http", "https", "mailto", "tel"]
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
/// blocks, top-level tables, and thematic breaks. Images stay unparsed as their alt text
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
        case table(Table)
        case thematicBreak
    }

    private struct Table {
        let columns: [PresentationIntent.TableColumn]
        let rows: [[AttributedString]]
        let source: String
    }

    private struct ListContext {
        /// Ordered-list counter shared across consecutive numbered lists.
        var number = 0
    }

    // MARK: Public API

    /// One attributed string for the whole reply.
    static func attributedString(for markdown: String, baseURL: URL? = nil) -> NSAttributedString {
        let blocks = parseBlocks(markdown, baseURL: baseURL)
        let attributed = NSMutableAttributedString()
        var listContext = ListContext()
        for (index, block) in blocks.enumerated() {
            if index > 0 { attributed.append(newline()) }
            render(block: block, into: attributed, baseURL: baseURL, listContext: &listContext)
        }
        return attributed
    }

    // MARK: Parsing

    private static func parseBlocks(_ markdown: String, baseURL: URL?) -> [Block] {
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

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            defer { lineIndex += 1 }
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
            if let (table, nextLine) = parseTable(in: lines, at: lineIndex, baseURL: baseURL) {
                flushAll()
                blocks.append(.table(table))
                lineIndex = nextLine - 1
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

    private static func parseTable(in lines: [String], at index: Int, baseURL: URL?) -> (Table, Int)? {
        guard index + 1 < lines.count else { return nil }
        let header = lines[index]
        let delimiter = lines[index + 1]
        guard header.contains("|") || delimiter.contains("|"),
              delimiter.contains("-"),
              delimiter.allSatisfy({ $0 == "|" || $0 == ":" || $0 == "-" || $0 == " " || $0 == "\t" }) else {
            return nil
        }
        // A body cell exposes table metadata even when every header cell is empty.
        guard let validation = try? AttributedString(
            markdown: header + "\n" + delimiter + "\ncell",
            options: .init(interpretedSyntax: .full)
        ) else { return nil }
        let columns = validation.runs.lazy.compactMap { run in
            run.presentationIntent?.components.compactMap { component -> [PresentationIntent.TableColumn]? in
                if case .table(let columns) = component.kind { return columns }
                return nil
            }.first
        }.first
        guard let columns, !columns.isEmpty else { return nil }

        var end = index + 2
        while end < lines.count {
            let line = lines[end]
            if line.trimmingCharacters(in: .whitespaces).isEmpty
                || line.hasPrefix("```") || line.hasPrefix("~~~")
                || isThematicBreak(line) || parseHeading(line) != nil
                || isQuoteLine(line) || isListLine(line) {
                break
            }
            end += 1
        }
        let source = lines[index..<end].joined(separator: "\n")
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true),
            baseURL: baseURL
        ) else { return nil }
        var rows = Array(
            repeating: Array(repeating: AttributedString(), count: columns.count),
            count: end - index - 1
        )
        for run in parsed.runs {
            guard let components = run.presentationIntent?.components else { return nil }
            var row: Int?
            var column: Int?
            for component in components {
                switch component.kind {
                case .tableHeaderRow: row = 0
                case .tableRow(let rowIndex): row = rowIndex
                case .tableCell(let columnIndex): column = columnIndex
                default: break
                }
            }
            guard let row, let column, rows.indices.contains(row), columns.indices.contains(column) else {
                return nil
            }
            rows[row][column].append(AttributedString(parsed[run.range]))
        }
        return (Table(columns: columns, rows: rows, source: source), end)
    }

    private static func fenceLanguage(_ fenceLine: String) -> String? {
        let info = fenceLine.drop { $0 == "`" || $0 == "~" || $0 == " " }
        return info.isEmpty ? nil : String(info)
    }

    private static func lineHasFenceEnd(_ line: String, open: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let openChar: Character = open.first == "~" ? "~" : "`"
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
        case .table(let table):
            appendTable(table, into: attributed, baseURL: baseURL)
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

    private static func appendTable(_ contents: Table, into attributed: NSMutableAttributedString, baseURL: URL?) {
        let table = NSTextTable()
        table.numberOfColumns = contents.columns.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        for (rowIndex, row) in contents.rows.enumerated() {
            for (columnIndex, content) in row.enumerated() {
                let cell = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1,
                    startingColumn: columnIndex, columnSpan: 1
                )
                cell.setContentWidth(100 / CGFloat(table.numberOfColumns), type: .percentageValueType)
                cell.setWidth(4, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                if rowIndex == 0 { cell.backgroundColor = .controlBackgroundColor }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [cell]
                paragraph.lineBreakMode = .byWordWrapping
                switch contents.columns[columnIndex].alignment {
                case .left: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                @unknown default: paragraph.alignment = .left
                }
                var attrs = baseAttributes()
                attrs[.paragraphStyle] = paragraph
                if rowIndex == 0 { attrs[.font] = NSFont.boldSystemFont(ofSize: 13) }
                appendParsedInline(content, source: contents.source, into: attributed, baseURL: baseURL, extraAttributes: attrs)
                attributed.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
    }

    // MARK: Inline rendering

    private static func appendInline(
        _ text: String,
        into attributed: NSMutableAttributedString,
        baseURL: URL?,
        extraAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true),
            baseURL: baseURL
        ) else {
            appendPlain(text, into: attributed, extraAttributes: extraAttributes)
            return
        }
        appendParsedInline(parsed, source: text, into: attributed, baseURL: baseURL, extraAttributes: extraAttributes)
    }

    private static func appendParsedInline(
        _ parsed: AttributedString,
        source: String,
        into attributed: NSMutableAttributedString,
        baseURL: URL?,
        extraAttributes: [NSAttributedString.Key: Any]? = nil
    ) {
        let inline = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attrs = extraAttributes ?? baseAttributes()
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
                let weight: NSFont.Weight = NSFontManager.shared.traits(of: font).contains(.boldFontMask) ? .bold : .regular
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: weight)
                attrs[.backgroundColor] = NSColor.controlBackgroundColor
            }
            if intent.contains(.stronglyEmphasized) {
                let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                attrs[.obliqueness] = 0.2
            }
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link { attrs[.link] = link }
            let content = String(parsed[run.range].characters)
            if run.imageURL != nil {
                attrs.removeValue(forKey: .link)
                let alt = content == "\u{FFFC}" ? "" : content
                let placeholder = alt.isEmpty ? "[image]" : "[image: \(alt)]"
                inline.append(NSAttributedString(string: placeholder, attributes: attrs))
            } else if run.link != nil,
                      let position = run.markdownSourcePosition,
                      let range = Range(position, in: source),
                      String(source[range]) != source {
                // Foundation strips label markup but omits its nested style intents.
                appendInline(String(source[range]), into: inline, baseURL: baseURL, extraAttributes: attrs)
            } else {
                inline.append(NSAttributedString(string: content, attributes: attrs))
            }
        }
        inline.enumerateAttribute(.link, in: NSRange(location: 0, length: inline.length), options: .reverse) { value, range, _ in
            guard let url = value as? URL else { return }
            if let scheme = url.scheme?.lowercased(), MarkdownTextLinkPolicy.schemes.contains(scheme) {
                inline.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            } else {
                inline.removeAttribute(.link, range: range)
                inline.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                var attrs = extraAttributes ?? baseAttributes()
                attrs.removeValue(forKey: .link)
                attrs[.foregroundColor] = NSColor.labelColor
                inline.insert(NSAttributedString(string: " (\(url.absoluteString))", attributes: attrs), at: NSMaxRange(range))
            }
        }
        attributed.append(inline)
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
}

// MARK: - NSAttributedString keys

extension NSAttributedString.Key {
    /// Marks spans that belong to a fenced code block. Value: opening
    /// fence string (e.g. "```swift").
    static let markdownCodeBlock = NSAttributedString.Key("com.businessbar.markdownCodeBlock")
}
