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
    /// The signed-in user's own RSVP state on this event. `.pending` means
    /// an invitation is waiting for an answer. Events without attendee
    /// records (personal calendars) report `.accepted`, not `.pending`, so
    /// they never trigger invitation popups.
    public let myRSVPStatus: RSVPStatus

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

    /// Mirror of EKParticipantStatus restricted to the values the RSVP flow
    /// needs. `unknown` keeps provider-agnostic events out of invite prompts.
    public enum RSVPStatus: String, Codable, Hashable {
        case unknown
        case pending
        case accepted
        case declined
        case tentative
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
        status: EventStatus = .confirmed,
        myRSVPStatus: RSVPStatus = .accepted
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
        self.myRSVPStatus = myRSVPStatus
    }

    public init(from ekEvent: EKEvent, calendar: MBCalendar) {
        // eventIdentifier is nil until EventKit persists the event; an
        // unsaved in-memory event must not trap the mapping.
        self.id = ekEvent.eventIdentifier ?? UUID().uuidString
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

        // The current user's own attendance record carries their RSVP state.
        // Events with no attendee list are personal entries, treated as
        // accepted so they never look like unanswered invitations.
        self.myRSVPStatus = Self.rsvpStatus(of: ekEvent)
    }

    private static func rsvpStatus(of ekEvent: EKEvent) -> RSVPStatus {
        guard let me = ekEvent.attendees?.first(where: { $0.isCurrentUser }) else {
            return .accepted
        }
        return rsvpStatus(of: me.participantStatus)
    }

    /// Maps a participant status onto the RSVP state. Own function so the
    /// mapping is testable directly: EKParticipant instances cannot be
    /// constructed outside a real event store.
    static func rsvpStatus(of status: EKParticipantStatus) -> RSVPStatus {
        switch status {
        case .pending: return .pending
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        default: return .unknown
        }
    }
}
