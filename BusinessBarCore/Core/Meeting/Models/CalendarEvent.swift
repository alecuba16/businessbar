import EventKit
import Foundation

public struct CalendarEvent: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let notes: String?
    public let url: URL?
    public let calendar: MBCalendar
    public let organizer: String?
    public let attendees: [String]
    public let isAllDay: Bool
    public let status: EventStatus

    public var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    public var isHappening: Bool {
        let now = Date()
        return now >= startDate && now <= endDate
    }

    public var meetingLink: URL? {
        MeetingLinkDetector.detectMeetingLink(in: self)
    }

    public enum EventStatus: String, Codable {
        case none
        case tentative
        case confirmed
        case canceled
    }

    /// Memberwise init for non-EventKit backends (e.g. Google Calendar).
    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        url: URL?,
        calendar: MBCalendar,
        organizer: String?,
        attendees: [String],
        isAllDay: Bool = false,
        status: EventStatus = .confirmed
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.url = url
        self.calendar = calendar
        self.organizer = organizer
        self.attendees = attendees
        self.isAllDay = isAllDay
        self.status = status
    }

    public init(from ekEvent: EKEvent, calendar: MBCalendar) {
        self.id = ekEvent.eventIdentifier
        self.title = ekEvent.title ?? "Untitled Event"
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.location = ekEvent.location
        self.notes = ekEvent.notes
        self.url = ekEvent.url
        self.calendar = calendar
        self.organizer = ekEvent.organizer?.name
        self.attendees = ekEvent.attendees?.compactMap { $0.name } ?? []
        self.isAllDay = ekEvent.isAllDay

        switch ekEvent.status {
        case .none:
            self.status = .none
        case .tentative:
            self.status = .tentative
        case .confirmed:
            self.status = .confirmed
        case .canceled:
            self.status = .canceled
        @unknown default:
            self.status = .none
        }
    }
}
