import AppKit
import EventKit
import Foundation
import os.log

@MainActor
public protocol CalendarStoreBackend {
    var hasAccess: Bool { get }
    func requestAccess() async throws -> Bool
    func refreshSources()
    func calendars() -> [EKCalendar]
    func events(from startDate: Date, to endDate: Date, calendars: [EKCalendar]) -> [EKEvent]
    /// Looks up the stored event by identifier. Returns nil when the event
    /// no longer exists in the Calendar database.
    func event(withID eventID: String) -> EKEvent?
    /// Persists an event edit, re-fetching the event if the passed instance
    /// was mutated outside the store.
    @discardableResult
    func save(_ event: EKEvent) throws -> Bool
}

@MainActor
private final class NativeCalendarStoreBackend: CalendarStoreBackend {
    private var store: EKEventStore
    /// Coverage seam: scenarios cannot grant real calendar access, so they
    /// inject the access answer while the store stays real.
    private let accessOverride: Bool?
    /// Coverage seam: headless hosts cannot answer a real TCC prompt, so
    /// scenarios inject a store whose access request answers immediately.
    /// Nil keeps the production EKEventStore() construction.
    private let storeProvider: (() -> EKEventStore)?

    init(store: EKEventStore = EKEventStore(), accessOverride: Bool? = nil, storeProvider: (() -> EKEventStore)? = nil) {
        self.store = store
        self.accessOverride = accessOverride
        self.storeProvider = storeProvider
    }

    var hasAccess: Bool {
        if let accessOverride { return accessOverride }
        return EKEventStore.authorizationStatus(for: .event) == .fullAccess
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
        // Plain init: EKEventStore(sources:) built from the pre-grant (empty)
        // source list yields a store whose calaccessd connection never initializes.
        store = storeProvider?() ?? EKEventStore()
    }

    func calendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    func events(from startDate: Date, to endDate: Date, calendars: [EKCalendar]) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return store.events(matching: predicate)
    }

    func event(withID eventID: String) -> EKEvent? {
        store.event(withIdentifier: eventID)
    }

    func save(_ event: EKEvent) throws -> Bool {
        try store.save(event, span: .thisEvent)
        return true
    }
}

@MainActor
public final class EKEventStoreAdapter: EventStoreProtocol {
    private static let logger = Logger(subsystem: "com.businessbar.app", category: "RSVP")

    private let backend: CalendarStoreBackend

    public convenience init() {
        self.init(backend: NativeCalendarStoreBackend())
    }

    /// Coverage seam: the real EventKit backend with the access answer
    /// injected. Event lookups and saves hit EventKit as in production; only
    /// the TCC-bound access flag is replaced, because scenarios cannot grant
    /// calendar permission. The store provider swaps in a store whose access
    /// request answers without a prompt, so headless hosts cannot hang on
    /// TCC; the requestAccess continuation body itself still executes.
    public static func nativeBackendForCoverage(
        store: EKEventStore = EKEventStore(),
        hasAccess: Bool,
        storeProvider: (() -> EKEventStore)? = nil
    ) -> CalendarStoreBackend {
        NativeCalendarStoreBackend(store: store, accessOverride: hasAccess, storeProvider: storeProvider)
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

    // MARK: - RSVP

    public func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
        guard backend.hasAccess else {
            Self.logger.warning("RSVP failed: calendar access not granted (event \(eventID, privacy: .public))")
            return false
        }
        guard let event = backend.event(withID: eventID) else {
            Self.logger.warning("RSVP failed: event not found for id \(eventID, privacy: .public)")
            return false
        }
        do {
            // EventKit on macOS exposes no public RSVP setter; Calendar.app
            // drives the same change through the private participationStatus
            // property. Used only here, guarded by responds(to:), with the
            // save as the failure point if the platform ever rejects it.
            let selector = NSSelectorFromString("setParticipationStatus:")
            guard event.responds(to: selector) else {
                Self.logger.warning("RSVP failed: setParticipationStatus selector unavailable on event \(eventID, privacy: .public)")
                return false
            }
            switch status {
            case .pending, .unknown:
                Self.logger.warning("RSVP failed: status \(status.rawValue, privacy: .public) is not answerable (event \(eventID, privacy: .public))")
                return false
            case .accepted:
                (event as NSObject).setValue(EKParticipantStatus.accepted.rawValue, forKey: "participationStatus")
            case .declined:
                (event as NSObject).setValue(EKParticipantStatus.declined.rawValue, forKey: "participationStatus")
            case .tentative:
                (event as NSObject).setValue(EKParticipantStatus.tentative.rawValue, forKey: "participationStatus")
            }
            let saved = try backend.save(event)
            if saved {
                Self.logger.info("RSVP saved: status \(status.rawValue, privacy: .public) for event \(eventID, privacy: .public)")
            } else {
                Self.logger.warning("RSVP failed: backend save returned false for event \(eventID, privacy: .public)")
            }
            return saved
        } catch {
            Self.logger.error("RSVP failed: save threw \(String(describing: error), privacy: .public) for event \(eventID, privacy: .public)")
            return false
        }
    }
}

enum EKAccessError: Error {
    case denied
}
