import XCTest
import EventKit
@testable import BusinessBarCore

// MARK: - Mock EventStore

final class MockEventStore: EventStoreProtocol {
    var stubbedCalendars: [MBCalendar] = []
    var stubbedEvents: [CalendarEvent] = []
    var requestAccessResult = true

    func requestAccess() async throws -> Bool { requestAccessResult }
    func fetchCalendars() async throws -> [MBCalendar] { stubbedCalendars }
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] {
        stubbedEvents
    }
}

// MARK: - MeetingManagerTests

@MainActor
final class MeetingManagerTests: XCTestCase {

    func test_initialStateHasNoEvents() {
        let store = MockEventStore()
        let manager = MeetingManager(eventStore: store)
        // Give the async init a moment but we can assert initial state is empty
        XCTAssertTrue(manager.events.isEmpty || manager.isLoading)
    }

    func test_nextEventIsNilWhenNoEvents() async throws {
        let store = MockEventStore()
        store.stubbedCalendars = [
            MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        ]
        store.stubbedEvents = []

        // Force the selected calendars defaults so the manager doesn't short-circuit
        let calendarData = try JSONEncoder().encode(["cal1"])
        UserDefaults.standard.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { UserDefaults.standard.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store)
        // Wait for async refresh
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(manager.nextEvent)
    }

    func test_nextEventIsSetWhenFutureEventExists() async throws {
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]

        let future = Date().addingTimeInterval(600)  // 10 minutes from now
        let event = CalendarEvent(
            id: "evt1",
            title: "Standup",
            startDate: future,
            endDate: future.addingTimeInterval(1800),
            location: nil,
            notes: nil,
            url: nil,
            calendar: calendar,
            organizer: nil,
            attendees: []
        )
        store.stubbedEvents = [event]

        let calendarData = try JSONEncoder().encode(["cal1"])
        UserDefaults.standard.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { UserDefaults.standard.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(manager.nextEvent?.id, "evt1")
    }

    func test_dismissedEventIsExcludedFromNextEvent() async throws {
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]

        let future = Date().addingTimeInterval(600)
        let event = CalendarEvent(
            id: "evt1",
            title: "Standup",
            startDate: future,
            endDate: future.addingTimeInterval(1800),
            location: nil,
            notes: nil,
            url: nil,
            calendar: calendar,
            organizer: nil,
            attendees: []
        )
        store.stubbedEvents = [event]

        let calendarData = try JSONEncoder().encode(["cal1"])
        UserDefaults.standard.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { UserDefaults.standard.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store)
        try await Task.sleep(nanoseconds: 200_000_000)

        manager.dismissEvent("evt1")
        XCTAssertNil(manager.nextEvent)
    }
}
