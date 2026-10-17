import Foundation

public final class MeetingLinkDetector {
    /// Compiled regexes are expensive; the service patterns are immutable,
    /// so compile each once and reuse across all lookups.
    private static let compiledPatterns: [(service: MeetingService, regex: NSRegularExpression)] =
        MeetingService.allCases.compactMap { service in
            guard let regex = try? NSRegularExpression(pattern: service.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (service, regex)
        }

    public static func detectMeetingLink(in event: CalendarEvent) -> URL? {
        let searchTexts = [
            event.url?.absoluteString,
            event.location,
            event.notes
        ].compactMap { $0 }
        return detectMeetingLink(in: searchTexts.joined(separator: " "))
    }

    /// Scans a free-form string for any recognised meeting URL.
    public static func detectMeetingLink(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        for (_, regex) in compiledPatterns {
            if let url = findURL(in: text, regex: regex, range: range) {
                return url
            }
        }
        return nil
    }

    private static func findURL(in text: String, regex: NSRegularExpression, range: NSRange) -> URL? {
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        let urlString = String(text[matchRange])
        return URL(string: urlString)
    }
}
