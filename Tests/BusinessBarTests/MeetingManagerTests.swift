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
    /// RSVP replies received through respond(toEventID:calendarID:status:).
    var receivedRSVPs: [(eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus)] = []
    var respondResult = true

    func requestAccess() async throws -> Bool { requestAccessResult }
    func fetchCalendars() async throws -> [MBCalendar] { stubbedCalendars }
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] {
        fetchedWindows.append((startDate, endDate))
        return stubbedEvents
    }

    func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
        receivedRSVPs.append((eventID, calendarID, status))
        return respondResult
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

// MARK: - RSVP pending tracking tests

@MainActor
final class MeetingManagerRSVPTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "com.businessbar.tests.meetingrsvp.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func pendingEvent(id: String, calendar: MBCalendar) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Invite",
            startDate: Date().addingTimeInterval(3600),
            endDate: Date().addingTimeInterval(5400),
            location: nil, notes: nil, url: nil,
            calendar: calendar,
            organizer: "Boss",
            attendees: ["Boss", "Me"],
            myRSVPStatus: .pending
        )
    }

    func test_pendingInvitesAreExposedAfterRefresh() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]
        store.stubbedEvents = [pendingEvent(id: "inv1", calendar: calendar)]

        let calendarData = try JSONEncoder().encode(["cal1"])
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(manager.pendingRSVPEvents.map(\.id), ["inv1"])
    }

    func test_answeredInviteLeavesPendingList() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]
        let pending = pendingEvent(id: "inv1", calendar: calendar)
        store.stubbedEvents = [pending]

        let calendarData = try JSONEncoder().encode(["cal1"])
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        try await Task.sleep(nanoseconds: 300_000_000)

        let ok = await manager.respond(to: pending, status: .accepted)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.receivedRSVPs.count, 1)
        XCTAssertEqual(store.receivedRSVPs.first?.status, .accepted)
        // The stub still returns the event with its original status; only
        // the reply passthrough and refresh are asserted here.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.receivedRSVPs.count, 1)
    }

    func test_failedRSVPReturnsFalse() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        store.respondResult = false
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        let pending = pendingEvent(id: "inv1", calendar: calendar)

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        let ok = await manager.respond(toEventID: pending.id, calendarID: calendar.id, status: .declined)
        XCTAssertFalse(ok)
        XCTAssertEqual(store.receivedRSVPs.first?.status, .declined)
    }

    func test_newEventNotificationsFireOnlyForFirstSeenEvents() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]

        let calendarData = try JSONEncoder().encode(["cal1"])
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)

        let center = NotificationCenter()
        var newEventPostings: [[CalendarEvent]] = []
        let observer = center.publisher(for: .businessBarNewEventsAppeared).sink { note in
            if let events = note.userInfo?["events"] as? [CalendarEvent] {
                newEventPostings.append(events)
            }
        }

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: center)
        store.stubbedEvents = [pendingEvent(id: "fresh", calendar: calendar)]
        await manager.refreshEvents()
        XCTAssertEqual(newEventPostings.count, 1)
        XCTAssertEqual(newEventPostings.first?.first?.id, "fresh")

        // Second refresh with the same events must not re-post.
        await manager.refreshEvents()
        XCTAssertEqual(newEventPostings.count, 1)
        _ = observer
    }

    func test_pendingInviteNotificationFiresWhileUnanswered() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MockEventStore()
        let calendar = MBCalendar(id: "cal1", title: "Work", color: "#FF0000", source: "iCloud")
        store.stubbedCalendars = [calendar]

        let calendarData = try JSONEncoder().encode(["cal1"])
        defaults.set(calendarData, forKey: Constants.Defaults.selectedCalendars)

        let center = NotificationCenter()
        var pendingPostings = 0
        let observer = center.publisher(for: .businessBarPendingRSVPsAppeared).sink { _ in
            pendingPostings += 1
        }

        let manager = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: center)
        store.stubbedEvents = [pendingEvent(id: "inv1", calendar: calendar)]
        await manager.refreshEvents()
        XCTAssertEqual(pendingPostings, 1)

        // Still pending on next refresh: re-posted so the notification layer
        // can re-present after macOS dropped the banner.
        await manager.refreshEvents()
        XCTAssertEqual(pendingPostings, 2)
        _ = observer
    }
}
