import XCTest
import EventKit
@testable import BusinessBarCore

// MARK: - Mock EventStore

final class MockEventStore: EventStoreProtocol {
    var stubbedCalendars: [MBCalendar] = []
    var stubbedEvents: [CalendarEvent] = []
    var requestAccessResult = true
    /// Windows requested by the manager, in order, so tests can observe
    /// how the fetch window moves across refreshes.
    var fetchedWindows: [(start: Date, end: Date)] = []

    func requestAccess() async throws -> Bool { requestAccessResult }
    func fetchCalendars() async throws -> [MBCalendar] { stubbedCalendars }
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] {
        fetchedWindows.append((startDate, endDate))
        return stubbedEvents
    }
}

// MARK: - MeetingManagerTests

@MainActor
final class MeetingManagerTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "com.businessbar.tests.meeting.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func test_initialStateHasNoEvents() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        // Give the async init a moment but we can assert initial state is empty
        XCTAssertTrue(manager.events.isEmpty || manager.isLoading)
    }

    func test_nextEventIsNilWhenNoEvents() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        store.stubbedCalendars = [
            MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        ]
        store.stubbedEvents = []

        // Force the selected calendars defaults so the manager doesn't short-circuit
        let calendarData = try JSONEncoder().encode(["cal1"])
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { defaults.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        // Wait for async refresh
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(manager.nextEvent)
    }

    func test_nextEventIsSetWhenFutureEventExists() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { defaults.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(manager.nextEvent?.id, "evt1")
    }

    func test_dismissedEventIsExcludedFromNextEvent() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { defaults.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        try await Task.sleep(nanoseconds: 200_000_000)

        manager.dismissEvent("evt1")
        XCTAssertNil(manager.nextEvent)
    }

    func test_dismissedIDsArePrunedWhenEventLeavesWindow() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]

        let future = Date().addingTimeInterval(600)
        let event = CalendarEvent(
            id: "evt1",
            title: "Standup",
            startDate: future,
            endDate: future.addingTimeInterval(1800),
            location: nil, notes: nil, url: nil,
            calendar: calendar, organizer: nil, attendees: []
        )
        store.stubbedEvents = [event]

        let calendarData = try JSONEncoder().encode(["cal1"])
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { defaults.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        try await Task.sleep(nanoseconds: 200_000_000)

        manager.dismissEvent("evt1")
        XCTAssertNil(manager.nextEvent, "dismissing must clear nextEvent immediately")

        // Dismissal is enforced by the filter on the next refresh.
        await manager.refreshEvents()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(manager.events.isEmpty, "dismissed event must be hidden from the visible list on refresh")

        // Event disappears from the source: refresh must prune the stale
        // dismissed ID instead of keeping it forever.
        store.stubbedEvents = []
        await manager.refreshEvents()
        try await Task.sleep(nanoseconds: 100_000_000)

        store.stubbedEvents = [event]
        await manager.refreshEvents()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            manager.events.map(\.id), ["evt1"],
            "event leaving the window must clear its dismissed ID so it shows again when it reappears"
        )
    }

    func test_midnightRolloverRefetchesAndWindowAdvances() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]

        var now = Date()
        let todayEvent = CalendarEvent(
            id: "today-evt",
            title: "Today",
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(5400),
            location: nil, notes: nil, url: nil,
            calendar: calendar, organizer: nil, attendees: []
        )
        store.stubbedEvents = [todayEvent]

        let calendarData = try JSONEncoder().encode(["cal1"])
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)
        defer { defaults.removeObject(forKey: Constants.Defaults.selectedCalendars) }

        let manager = MeetingManager(eventStore: store, nowProvider: { now }, defaults: defaults, notificationCenter: NotificationCenter())
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(manager.events.map(\.id), ["today-evt"])
        XCTAssertEqual(store.fetchedWindows.count, 1, "initial refresh should fetch exactly one window")

        // Simulate the day changing under the app while it stays running.
        // Jump to midday tomorrow so the day boundary is unambiguous in any
        // timezone or DST regime.
        let nextDayNoon = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)
        )!.addingTimeInterval(12 * 3600)
        now = nextDayNoon
        let newDayEvent = CalendarEvent(
            id: "new-day-evt",
            title: "New Day",
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(5400),
            location: nil, notes: nil, url: nil,
            calendar: calendar, organizer: nil, attendees: []
        )
        store.stubbedEvents = [todayEvent, newDayEvent]

        manager.recalculateNextEvent()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(store.fetchedWindows.count, 2, "day change must trigger a refetch")
        let dayDelta = Calendar.current.dateComponents([.day], from: store.fetchedWindows[0].start, to: store.fetchedWindows[1].start).day
        XCTAssertEqual(dayDelta, 1, "fetch window must advance by exactly one day on rollover")
        XCTAssertTrue(
            manager.events.map(\.id).contains("new-day-evt"),
            "events on the new day must be loaded after rollover"
        )
    }
}
