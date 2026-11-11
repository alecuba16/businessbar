import Combine
import EventKit
import Foundation
import os.log

@MainActor
public final class MeetingManager: ObservableObject {
    @Published public private(set) var events: [CalendarEvent] = []
    @Published public private(set) var nextEvent: CalendarEvent?
    @Published public private(set) var calendars: [MBCalendar] = []
    @Published public private(set) var isLoading = false
    /// Events whose invitation is still waiting for the user's answer.
    /// Drives the status-bar pending badge, the menu invites section, and
    /// the RSVP panel.
    @Published public private(set) var pendingRSVPEvents: [CalendarEvent] = []

    private static let logger = Logger(subsystem: "com.businessbar.app", category: "Meeting")

    private let eventStore: EventStoreProtocol
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    /// Injectable clock. Tests pass a closure over a mutable date to simulate
    /// midnight rollover without waiting for a real day change.
    private let nowProvider: () -> Date
    private var cancellables = Set<AnyCancellable>()

    /// Dismissed event IDs are pruned to IDs still present in the current
    /// fetch window on every refresh, so the set cannot grow without bound
    /// across weeks of 24/7 uptime.
    private var dismissedEventIDs = Set<String>()

    /// Start of the day the last successful fetch covered. Used by the
    /// periodic tick to detect midnight rollover and trigger a full refresh
    /// so the fetch window advances to the new day.
    private var lastFetchDayStart: Date?
    /// IDs of events already seen in a previous fetch. First-seen events
    /// feed the new-event confirmation notification. Survives refreshes,
    /// resets when the calendar feature turns off so a later re-enable does
    /// not replay the whole day as "new".
    private var seenEventIDs = Set<String>()
    private var lastFeatureState: Bool {
        didSet {
            if !lastFeatureState {
                events = []
                nextEvent = nil
                calendars = []
                pendingRSVPEvents = []
                dismissedEventIDs.removeAll()
                seenEventIDs.removeAll()
                lastFetchDayStart = nil
            }
        }
    }

    private var showTomorrowEvents: Bool {
        if let value = defaults.object(forKey: Constants.Defaults.showTomorrowEvents) as? Bool {
            return value
        }
        return true
    }

    public init(
        eventStore: EventStoreProtocol,
        nowProvider: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.eventStore = eventStore
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.nowProvider = nowProvider
        self.lastFeatureState = defaults.object(forKey: Constants.Defaults.featureCalendar) as? Bool ?? true

        setupEventStoreObserver()
        setupPreferencesObserver()

        Task {
            guard calendarFeatureEnabled() else {
                events = []
                nextEvent = nil
                calendars = []
                pendingRSVPEvents = []
                return
            }
            await loadCalendars()
            await refreshEvents()
        }
    }

    public func requestAccess() async throws -> Bool {
        try await eventStore.requestAccess()
    }

    public func loadCalendars() async {
        guard calendarFeatureEnabled() else {
            calendars = []
            return
        }
        do {
            calendars = try await eventStore.fetchCalendars()
        } catch {
            // Expected during first launch (permission not yet granted) or
            // when Google provider is selected but not yet signed in.
            // Callers handle the empty-list state via UI.
        }
    }

    public func refreshEvents() async {
        guard calendarFeatureEnabled() else {
            events = []
            nextEvent = nil
            pendingRSVPEvents = []
            lastFetchDayStart = nil
            return
        }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let selectedCalendarIDs = getSelectedCalendarIDs()

            guard !selectedCalendarIDs.isEmpty else {
                events = []
                nextEvent = nil
                return
            }

            let showTomorrow = showTomorrowEvents
            let window = EventDisplayPlanner.fetchWindow(now: nowProvider(), includeTomorrow: showTomorrow)

            var fetchedEvents = try await eventStore.fetchEvents(
                from: window.start,
                to: window.end,
                calendars: selectedCalendarIDs
            )

            pruneDismissedIDs(keeping: fetchedEvents)

            fetchedEvents = EventDisplayPlanner.filter(
                fetchedEvents,
                dismissedIDs: dismissedEventIDs,
                showDeclined: defaults.bool(forKey: Constants.Defaults.showDeclinedEvents)
            )
            if !showTomorrow {
                fetchedEvents = fetchedEvents.filter { $0.startDate < window.end }
            }
            fetchedEvents.sort { $0.startDate < $1.startDate }

            let newlySeenEvents = fetchedEvents.filter { !seenEventIDs.contains($0.id) }
            for event in fetchedEvents {
                seenEventIDs.insert(event.id)
            }

            events = fetchedEvents
            pendingRSVPEvents = fetchedEvents.filter { $0.myRSVPStatus == .pending }
            nextEvent = EventDisplayPlanner.nextEvent(from: fetchedEvents, dismissedIDs: dismissedEventIDs, now: nowProvider())
            lastFetchDayStart = window.start

            if !newlySeenEvents.isEmpty {
                notificationCenter.post(
                    name: .businessBarNewEventsAppeared,
                    object: nil,
                    userInfo: ["events": newlySeenEvents]
                )
            }
            if !pendingRSVPEvents.isEmpty {
                notificationCenter.post(
                    name: .businessBarPendingRSVPsAppeared,
                    object: nil,
                    userInfo: ["events": pendingRSVPEvents]
                )
            }
        } catch {
            Self.logger.error("Failed to refresh events: \(error.localizedDescription)")
        }
    }

    public func dismissEvent(_ eventID: String) {
        dismissedEventIDs.insert(eventID)
        nextEvent = EventDisplayPlanner.nextEvent(from: events, dismissedIDs: dismissedEventIDs, now: nowProvider())
    }

    /// Sends the user's RSVP answer for one event through the active store
    /// and refreshes so the badge, menu, and next-event pick up the change.
    /// Returns false when the store rejected the answer.
    @discardableResult
    public func respond(to event: CalendarEvent, status: CalendarEvent.RSVPStatus) async -> Bool {
        let ok = await eventStore.respond(toEventID: event.id, calendarID: event.calendar.id, status: status)
        if ok {
            await refreshEvents()
        }
        return ok
    }

    /// Same as `respond(to:status:)` for callers that only carry the event
    /// and calendar identifiers (notification action routing).
    @discardableResult
    public func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
        let ok = await eventStore.respond(toEventID: eventID, calendarID: calendarID, status: status)
        if ok {
            await refreshEvents()
        }
        return ok
    }

    /// Recalculation of `nextEvent` from the cached events array, plus day
    /// rollover detection: when the calendar day changed since the last
    /// successful fetch, kicks a full `refreshEvents()` so the fetch window
    /// advances. The tick stays responsive either way: the cache-based
    /// recalculation below runs immediately, the refresh lands async.
    public func recalculateNextEvent() {
        if hasDayChangedSinceLastFetch() {
            Task { @MainActor [weak self] in
                await self?.refreshEvents()
            }
        }
        nextEvent = EventDisplayPlanner.nextEvent(from: events, dismissedIDs: dismissedEventIDs, now: nowProvider())
    }

    private func hasDayChangedSinceLastFetch(calendar: Calendar = .current) -> Bool {
        guard let lastFetchDayStart else { return false }
        return calendar.startOfDay(for: nowProvider()) != lastFetchDayStart
    }

    /// Drops dismissed IDs that no longer appear in the fetched events,
    /// keeping the set bounded to the visible window.
    private func pruneDismissedIDs(keeping fetchedEvents: [CalendarEvent]) {
        let currentIDs = Set(fetchedEvents.map { $0.id })
        dismissedEventIDs = dismissedEventIDs.intersection(currentIDs)
    }

    private func getSelectedCalendarIDs() -> [String] {
        guard let data = defaults.data(forKey: Constants.Defaults.selectedCalendars),
              let calendarIDs = try? JSONDecoder().decode([String].self, from: data) else {
            return calendars.map { $0.id }
        }

        return calendarIDs
    }

    private func setupEventStoreObserver() {
        notificationCenter.publisher(for: .EKEventStoreChanged)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.calendarFeatureEnabled() else { return }
                    await self.refreshEvents()
                }
            }
            .store(in: &cancellables)
    }

    private func setupPreferencesObserver() {
        notificationCenter.publisher(for: .businessBarPreferencesDidChange)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let isEnabled = self.calendarFeatureEnabled()
                    if isEnabled != self.lastFeatureState {
                        self.lastFeatureState = isEnabled
                        guard isEnabled else { return }
                        await self.loadCalendars()
                    }
                    guard isEnabled else { return }
                    await self.refreshEvents()
                }
            }
            .store(in: &cancellables)
    }

    private func calendarFeatureEnabled() -> Bool {
        if let value = defaults.object(forKey: Constants.Defaults.featureCalendar) as? Bool {
            return value
        }
        return true
    }
}
