import EventKit
import Foundation

public struct MBCalendar: Identifiable, Hashable, Codable {
    public let id: String
    public let title: String
    public let source: String
    public let color: String

    public init(from ekCalendar: EKCalendar) {
        self.id = ekCalendar.calendarIdentifier
        self.title = ekCalendar.title
        self.source = ekCalendar.source.title
        self.color = ekCalendar.color.hexString
    }

    /// Memberwise init for non-EventKit backends (e.g. Google Calendar).
    public init(id: String, title: String, color: String, source: String) {
        self.id = id
        self.title = title
        self.color = color
        self.source = source
    }
}
