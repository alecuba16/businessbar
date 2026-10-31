import AppKit
import EventKit
import Foundation

@MainActor
public protocol CalendarStoreBackend {
    var hasAccess: Bool { get }
    func requestAccess() async throws -> Bool
    func refreshSources()
    func calendars() -> [EKCalendar]
    func events(from startDate: Date, to endDate: Date, calendars: [EKCalendar]) -> [EKEvent]
}

@MainActor
private final class NativeCalendarStoreBackend: CalendarStoreBackend {
    private var store = EKEventStore()

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            // Completion handlers reliably present TCC prompts in LSUIElement apps.
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func refreshSources() {
        store = EKEventStore(sources: store.sources + store.delegateSources)
    }

    func calendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    func events(from startDate: Date, to endDate: Date, calendars: [EKCalendar]) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return store.events(matching: predicate)
    }
}

@MainActor
public final class EKEventStoreAdapter: EventStoreProtocol {
    private let backend: CalendarStoreBackend

    public convenience init() {
        self.init(backend: NativeCalendarStoreBackend())
    }

    public init(backend: CalendarStoreBackend) {
        self.backend = backend
    }

    public func requestAccess() async throws -> Bool {
        guard try await backend.requestAccess() else { throw EKAccessError.denied }
        backend.refreshSources()
        return true
    }

    public func fetchCalendars() async throws -> [MBCalendar] {
        guard backend.hasAccess else { return [] }
        return backend.calendars().map { MBCalendar(from: $0) }
    }

    public func fetchEvents(from startDate: Date, to endDate: Date, calendars calendarIDs: [String]) async throws -> [CalendarEvent] {
        guard backend.hasAccess else { return [] }
        let calendars = backend.calendars().filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        return backend.events(from: startDate, to: endDate, calendars: calendars).map {
            CalendarEvent(from: $0, calendar: MBCalendar(from: $0.calendar))
        }
    }
}

enum EKAccessError: Error {
    case denied
}
