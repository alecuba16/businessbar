import EventKit
import Foundation

@MainActor
public protocol EventStoreProtocol {
    func requestAccess() async throws -> Bool
    func fetchCalendars() async throws -> [MBCalendar]
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent]
    /// Writes the signed-in user's RSVP answer for the given event.
    /// Returns false when the backend cannot reply (no write access,
    /// event not found, provider unsupported).
    @discardableResult
    func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool
}
