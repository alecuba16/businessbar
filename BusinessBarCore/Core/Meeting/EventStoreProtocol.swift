import EventKit
import Foundation

@MainActor
public protocol EventStoreProtocol {
    func requestAccess() async throws -> Bool
    func fetchCalendars() async throws -> [MBCalendar]
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent]
}
