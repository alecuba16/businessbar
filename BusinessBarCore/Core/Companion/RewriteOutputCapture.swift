import Foundation

// MARK: - RewriteOutputCapture

/// Extracts the raw rewritten text from a model reply. Rewrite templates
/// instruct the model to wrap the result in `<output>` tags; when it
/// complies, everything outside the tags is discarded. When it does not,
/// a leading commentary line is stripped so the overlay never starts with
/// "Here's what I fixed:".
public enum RewriteOutputCapture {

    static let openingTag = "<output>"
    static let closingTag = "</output>"

    /// True when the reply contains a complete <output></output> pair.
    /// Auto-replace templates only act on tagged replies, so a reply that
    /// ignored the format never overwrites the selection.
    public static func containsOutputTags(_ reply: String) -> Bool {
        guard let openingRange = reply.range(of: openingTag) else { return false }
        return reply.range(of: closingTag, range: openingRange.upperBound..<reply.endIndex) != nil
    }

    /// Returns the text to show in the rewrite overlay.
    public static func capture(from reply: String) -> String {
        if let tagged = contentInsideTags(reply) {
            return unwrappedFromCodeFence(tagged)
        }

        // No tags: the model ignored the format instruction. Drop a single
        // leading line when it reads like commentary ("Here is the...",
        // "I fixed...", "Sure!..."). Only one line, and only when another
        // line follows, so a legitimate one-line rewrite survives.
        if let stripped = strippingLeadingCommentary(reply) {
            return stripped
        }
        return reply
    }

    /// Content between the first `<output>` and its matching closing tag,
    /// trimmed. Nil when no complete pair exists.
    private static func contentInsideTags(_ text: String) -> String? {
        guard let openingRange = text.range(of: openingTag) else { return nil }
        let afterOpening = openingRange.upperBound
        guard let closingRange = text.range(of: closingTag, range: afterOpening..<text.endIndex)
        else { return nil }

        let inner = String(text[afterOpening..<closingRange.lowerBound])
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Models often wrap the result in a ``` fence even inside the tags.
    /// A lone fence pair around the whole content is removed; fences
    /// inside the content (code the user actually wants) stay.
    private static func unwrappedFromCodeFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
              isFenceLine(lines.first ?? ""),
              isFenceLine(lines.last ?? "")
        else { return text }

        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```")
    }

    /// Strips one leading commentary line, only when the reply has more
    /// content after it and the line looks like an introduction rather
    /// than the rewrite itself.
    private static func strippingLeadingCommentary(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        let first = lines[0].trimmingCharacters(in: .whitespaces)
        guard looksLikeCommentary(first) else { return nil }

        lines.removeFirst()
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeCommentary(_ line: String) -> Bool {
        let lower = line.lowercased()
        let starters = [
            "here's what i fixed",
            "here is what i fixed",
            "here's the corrected",
            "here is the corrected",
            "here's the improved",
            "here is the improved",
            "here's the rewritten",
            "here is the rewritten",
            "here's the translation",
            "here is the translation",
            "here's your",
            "here is your",
            "sure,",
            "sure!",
            "certainly,",
            "certainly!",
            "i corrected",
            "i fixed",
            "i improved",
            "i rewrote",
            "i translated",
            "the corrected text",
            "the improved text",
            "the rewritten text"
        ]
        return starters.contains { lower.hasPrefix($0) }
    }
}
