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
    private var lastFeatureState: Bool {
        didSet {
            if !lastFeatureState {
                events = []
                nextEvent = nil
                calendars = []
                dismissedEventIDs.removeAll()
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

            events = fetchedEvents
            nextEvent = EventDisplayPlanner.nextEvent(from: fetchedEvents, dismissedIDs: dismissedEventIDs, now: nowProvider())
            lastFetchDayStart = window.start
        } catch {
            Self.logger.error("Failed to refresh events: \(error.localizedDescription)")
        }
    }

    public func dismissEvent(_ eventID: String) {
        dismissedEventIDs.insert(eventID)
        nextEvent = EventDisplayPlanner.nextEvent(from: events, dismissedIDs: dismissedEventIDs, now: nowProvider())
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
