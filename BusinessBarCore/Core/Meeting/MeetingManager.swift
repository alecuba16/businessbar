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
    private var cancellables = Set<AnyCancellable>()

    private var dismissedEventIDs = Set<String>()
    private var lastFeatureState: Bool {
        didSet {
            if !lastFeatureState {
                events = []
                nextEvent = nil
                calendars = []
            }
        }
    }

    private var showTomorrowEvents: Bool {
        if let value = UserDefaults.standard.object(forKey: Constants.Defaults.showTomorrowEvents) as? Bool {
            return value
        }
        return true
    }

    public init(eventStore: EventStoreProtocol) {
        self.eventStore = eventStore
        self.lastFeatureState = Self.calendarFeatureEnabled()

        setupEventStoreObserver()
        setupPreferencesObserver()

        Task {
            guard Self.calendarFeatureEnabled() else {
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
        guard Self.calendarFeatureEnabled() else {
            calendars = []
            return
        }
        do {
            calendars = try await eventStore.fetchCalendars()
        } catch {
            // Expected during first launch (permission not yet granted) or
            // when Google provider is selected but not yet signed in.
            // Not printed — callers handle the empty-list state via UI.
        }
    }

    public func refreshEvents() async {
        guard Self.calendarFeatureEnabled() else {
            events = []
            nextEvent = nil
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

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let endDate = showTomorrowEvents
            ? calendar.date(byAdding: .day, value: 2, to: startOfToday)!
            : startOfTomorrow

        var fetchedEvents = try await eventStore.fetchEvents(
            from: startOfToday,
            to: endDate,
            calendars: selectedCalendarIDs
        )

        fetchedEvents = filterEvents(fetchedEvents)
        if !showTomorrowEvents {
            fetchedEvents = fetchedEvents.filter { $0.startDate < startOfTomorrow }
        }
            fetchedEvents.sort { $0.startDate < $1.startDate }

            events = fetchedEvents
            nextEvent = calculateNextEvent()
        } catch {
            Self.logger.error("Failed to refresh events: \(error.localizedDescription)")
        }
    }

    public func dismissEvent(_ eventID: String) {
        dismissedEventIDs.insert(eventID)
        nextEvent = calculateNextEvent()
    }

    /// Lightweight recalculation of `nextEvent` from the cached events array.
    /// Call periodically so ended events are pruned without a full network/store refresh.
    public func recalculateNextEvent() {
        nextEvent = calculateNextEvent()
    }

    private func filterEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let showDeclined = UserDefaults.standard.bool(forKey: Constants.Defaults.showDeclinedEvents)

        return events.filter { event in
            if dismissedEventIDs.contains(event.id) {
                return false
            }

            if !showDeclined && event.status == .canceled {
                return false
            }

            return true
        }
    }

    private func calculateNextEvent() -> CalendarEvent? {
        let now = Date()

        for event in events where !dismissedEventIDs.contains(event.id) {
            if event.endDate > now {
                return event
            }
        }

        return nil
    }

    private func getSelectedCalendarIDs() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: Constants.Defaults.selectedCalendars),
              let calendarIDs = try? JSONDecoder().decode([String].self, from: data) else {
            return calendars.map { $0.id }
        }

        return calendarIDs
    }

    private func setupEventStoreObserver() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard Self.calendarFeatureEnabled() else { return }
                    await self?.refreshEvents()
                }
            }
            .store(in: &cancellables)
    }

    private func setupPreferencesObserver() {
        NotificationCenter.default.publisher(for: .businessBarPreferencesDidChange)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let isEnabled = Self.calendarFeatureEnabled()
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

    nonisolated private static func calendarFeatureEnabled() -> Bool {
        if let value = UserDefaults.standard.object(forKey: Constants.Defaults.featureCalendar) as? Bool {
            return value
        }
        return true
    }
}
