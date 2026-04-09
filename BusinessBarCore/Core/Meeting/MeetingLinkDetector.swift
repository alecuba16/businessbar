import Foundation

public final class MeetingLinkDetector {
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
        for service in MeetingService.allCases {
            if let url = findURL(in: text, matching: service.pattern) {
                return url
            }
        }
        return nil
    }

    private static func findURL(in text: String, matching pattern: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        guard let matchRange = Range(match.range, in: text) else {
            return nil
        }

        let urlString = String(text[matchRange])
        return URL(string: urlString)
    }
}
