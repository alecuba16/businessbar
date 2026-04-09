import AppKit
import EventKit
import Foundation

// EKEventStore operations must run on the main thread on macOS 14+.
// Marking the adapter @MainActor ensures requestAccess(), fetchCalendars(),
// and fetchEvents() are always dispatched there.
@MainActor
public final class EKEventStoreAdapter: EventStoreProtocol {
    // Private instance — recreated after permission grant to include delegate
    // sources (e.g. Exchange delegates).  Owned exclusively by this
    // @MainActor-isolated instance, eliminating the data-race risk of the
    // previous nonisolated(unsafe) static var pattern.
    private var _eventStore = EKEventStore()

    public init() {}

    private static var hasCalendarAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess
    }

    public func requestAccess() async throws -> Bool {
        // Capture the current store on MainActor before entering the
        // @Sendable completion handler.
        let store = _eventStore

        let granted = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            // Use the completion-handler API (not async/await) — the async
            // variant has known issues with LSUIElement apps on macOS 14
            // where the TCC dialog silently does nothing. The completion
            // handler fires correctly.
            let handler: @Sendable (Bool, Error?) -> Void = { granted, error in
                if let error {
                    cont.resume(throwing: error)
                } else if granted {
                    cont.resume(returning: true)
                } else {
                    cont.resume(throwing: EKAccessError.denied)
                }
            }

            if #available(macOS 14, *) {
                store.requestFullAccessToEvents(completion: handler)
            } else {
                store.requestAccess(to: .event, completion: handler)
            }
        }

        // Access was granted — rebuild store to include delegated calendar
        // sources (e.g. Exchange delegates).  This runs on MainActor, so
        // mutating _eventStore is safe.
        var sources = store.sources
        sources.append(contentsOf: store.delegateSources)
        _eventStore = EKEventStore(sources: sources)

        return granted
    }

    public func fetchCalendars() async throws -> [MBCalendar] {
        guard Self.hasCalendarAccess else { return [] }
        return _eventStore.calendars(for: .event).map { MBCalendar(from: $0) }
    }

    public func fetchEvents(from startDate: Date, to endDate: Date, calendars calendarIDs: [String]) async throws -> [CalendarEvent] {
        guard Self.hasCalendarAccess else { return [] }

        let ekCalendars = _eventStore.calendars(for: .event)
            .filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !ekCalendars.isEmpty else { return [] }

        let predicate = _eventStore.predicateForEvents(
            withStart: startDate, end: endDate, calendars: ekCalendars
        )
        return _eventStore.events(matching: predicate).map { ekEvent in
            CalendarEvent(from: ekEvent, calendar: MBCalendar(from: ekEvent.calendar))
        }
    }
}

enum EKAccessError: Error {
    case denied
}
