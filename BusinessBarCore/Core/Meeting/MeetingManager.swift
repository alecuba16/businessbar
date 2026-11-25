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
    /// the RSVP panel. Events that already ended are excluded: a pending
    /// status on a past invitation is stale bookkeeping, not a question.
    @Published public private(set) var pendingRSVPEvents: [CalendarEvent] = []
    /// Events first observed within the last 24 h, newest first, minus rows
    /// the user marked as read. Drives the menu's recently-added region.
    /// Session memory only: it starts empty on launch and empties when the
    /// calendar feature turns off.
    @Published public private(set) var recentEvents: [CalendarEvent] = []
    /// Already-seen events whose start or end moved in the latest refresh.
    /// Drives the orange "N!" status-bar badge and the menu's changed-times
    /// region. Session memory only: the first fetch of a session cannot
    /// produce changes because there is nothing to compare against.
    @Published public private(set) var timeChangedEvents: [CalendarEvent] = []

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

    /// Recently-added rows the user marked as read. Pruned with the same
    /// fetch-window rule as `dismissedEventIDs`, so a row can come back only
    /// after its event left the fetch window or the app restarted.
    private var readRecentEventIDs = Set<String>()

    /// Start of the day the last successful fetch covered. Used by the
    /// periodic tick to detect midnight rollover and trigger a full refresh
    /// so the fetch window advances to the new day.
    private var lastFetchDayStart: Date?
    /// IDs of events already seen in a previous fetch. First-seen events
    /// feed the new-event confirmation notification. Survives refreshes,
    /// resets when the calendar feature turns off so a later re-enable does
    /// not replay the whole day as "new".
    private var seenEventIDs = Set<String>()
    /// When each event was first observed, for the recently-added region.
    /// Same lifecycle as `seenEventIDs`: cleared with the feature toggle and
    /// session-only, so a restart restarts the list as the UI states.
    private var firstSeenAt = [String: Date]()
    /// Last fetched events covering the whole horizon, before the agenda
    /// display cut. The read-row recompute runs on the full window because
    /// a recent row can sit on a day the agenda does not list. Notification
    /// scheduling stays on the agenda on purpose: every refresh re-schedules
    /// from the current list, so events only need coverage once they land
    /// in the two-day window.
    public private(set) var horizonEvents: [CalendarEvent] = []
    /// Last observed time window per seen occurrence, for change detection.
    /// Keyed by occurrence, not by event id: occurrences of one recurring
    /// series share the id in both backends, so id alone would collapse
    /// them and every fetch would report a phantom change. Same lifecycle
    /// as `seenEventIDs`: a first-seen occurrence never counts as changed,
    /// only a later shift of its start or end does.
    private var lastSeenWindows = [String: (start: Date, end: Date)]()
    private var lastFeatureState: Bool {
        didSet {
            if !lastFeatureState {
                events = []
                nextEvent = nil
                calendars = []
                pendingRSVPEvents = []
                recentEvents = []
                timeChangedEvents = []
                dismissedEventIDs.removeAll()
                acknowledgedChangeWindows.removeAll()
                readRecentEventIDs.removeAll()
                seenEventIDs.removeAll()
                firstSeenAt.removeAll()
                lastSeenWindows.removeAll()
                horizonEvents = []
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

    /// Row cap for the menu's Recently added region.
    private var recentEventsLimit: Int {
        let value = defaults.integer(forKey: Constants.Defaults.recentEventsLimit)
        return value > 0 ? value : Constants.DefaultValues.recentEventsLimit
    }

    /// First-seen window for the same region, in days.
    private var recentEventsWindow: TimeInterval {
        let days = defaults.object(forKey: Constants.Defaults.recentEventsWindowDays) as? Int
            ?? Constants.DefaultValues.recentEventsWindowDays
        return TimeInterval(max(1, days)) * 24 * 3600
    }

    /// How many days ahead the fetch window reaches. Everything from the
    /// start of today to this horizon is polled every refresh, so the
    /// recently-added region, change detection, and notifications cover
    /// events scheduled on any future day, not just today and tomorrow.
    private var fetchHorizonDays: Int {
        let days = defaults.object(forKey: Constants.Defaults.fetchHorizonDays) as? Int
            ?? Constants.DefaultValues.fetchHorizonDays
        return max(1, days)
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
                recentEvents = []
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
            recentEvents = []
            timeChangedEvents = []
            horizonEvents = []
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
                horizonEvents = []
                return
            }

            let showTomorrow = showTomorrowEvents
            let now = nowProvider()
            let window = EventDisplayPlanner.fetchWindow(
                now: now,
                includeTomorrow: showTomorrow,
                horizonDays: fetchHorizonDays
            )

            var fetchedEvents = try await eventStore.fetchEvents(
                from: window.start,
                to: window.end,
                calendars: selectedCalendarIDs
            )

            pruneDismissedIDs(keeping: fetchedEvents)
            pruneReadRecentIDs(keeping: fetchedEvents)

            fetchedEvents = EventDisplayPlanner.filter(
                fetchedEvents,
                dismissedIDs: dismissedEventIDs,
                showDeclined: defaults.bool(forKey: Constants.Defaults.showDeclinedEvents)
            )
            fetchedEvents.sort { $0.startDate < $1.startDate }

            let newlySeenEvents = fetchedEvents.filter { !seenEventIDs.contains($0.id) }
            for event in fetchedEvents {
                seenEventIDs.insert(event.id)
                if firstSeenAt[event.id] == nil {
                    firstSeenAt[event.id] = now
                }
            }

            // Time-change detection compares against the previous fetch's
            // window. First-seen occurrences have no memory yet, so they
            // never count as changed. Ended occurrences are excluded too:
            // a moved meeting in the past cannot be joined or rescheduled,
            // so flagging it only turns the badge into permanent noise.
            // Acknowledged rows re-flag only when their times move again.
            let changedTimeEvents = fetchedEvents.filter { event in
                let key = Self.changeKey(event)
                guard !dismissedEventIDs.contains(event.id),
                      event.endDate > now,
                      let previous = lastSeenWindows[key] else { return false }
                if let acknowledged = acknowledgedChangeWindows[key],
                   event.startDate == acknowledged.start,
                   event.endDate == acknowledged.end {
                    return false
                }
                return previous.start != event.startDate || previous.end != event.endDate
            }
            for event in fetchedEvents {
                lastSeenWindows[Self.changeKey(event)] = (event.startDate, event.endDate)
            }
            let currentChangeKeys = Set(fetchedEvents.map(Self.changeKey))
            for key in Set(lastSeenWindows.keys).subtracting(currentChangeKeys) {
                lastSeenWindows.removeValue(forKey: key)
            }
            for key in Set(acknowledgedChangeWindows.keys).subtracting(currentChangeKeys) {
                acknowledgedChangeWindows.removeValue(forKey: key)
            }
            timeChangedEvents = changedTimeEvents

            recentEvents = EventDisplayPlanner.recentEvents(
                firstSeen: firstSeenAt,
                from: fetchedEvents.filter { !readRecentEventIDs.contains($0.id) },
                now: now,
                window: recentEventsWindow,
                limit: recentEventsLimit
            )

            // Agenda display keeps its own two-day model regardless of the
            // fetch horizon: the menu lists today, plus tomorrow when the
            // toggle is on. Everything else the wide fetch feeds (recently
            // added, changed times, invites, notifications) works on the
            // whole horizon.
            let agendaEnd = Calendar.current.date(
                byAdding: .day,
                value: showTomorrow ? 2 : 1,
                to: Calendar.current.startOfDay(for: now)
            )!
            let agendaEvents = fetchedEvents.filter { $0.startDate < agendaEnd }

            events = agendaEvents
            pendingRSVPEvents = EventDisplayPlanner.pendingInvites(from: fetchedEvents, now: now)
            nextEvent = EventDisplayPlanner.nextEvent(from: agendaEvents, dismissedIDs: dismissedEventIDs, now: now)
            horizonEvents = fetchedEvents
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
            if !timeChangedEvents.isEmpty {
                notificationCenter.post(
                    name: .businessBarEventTimesChanged,
                    object: nil,
                    userInfo: ["events": timeChangedEvents]
                )
            }
        } catch {
            Self.logger.error("Failed to refresh events: \(error.localizedDescription)")
        }
    }

    /// Acknowledged time windows per occurrence: a changed-times row the
    /// user marked read stays quiet while its times hold still and re-flags
    /// only when they move again, because a new shift is new information.
    /// Pruned with the same fetch-window rule as the other memories.
    private var acknowledgedChangeWindows = [String: (start: Date, end: Date)]()

    /// Identifies one occurrence of an event. Recurring occurrences share
    /// their event id in both backends, so the occurrence date separates
    /// them; a whole-series edit shifts every occurrence date, which makes
    /// it land as a first-seen key (announced once as changed, then quiet).
    private static func changeKey(_ event: CalendarEvent) -> String {
        if event.isRecurring, let occurrence = event.occurrenceDate {
            return "\(event.id)#\(occurrence.timeIntervalSince1970)"
        }
        return event.id
    }

    public func dismissEvent(_ eventID: String) {
        dismissedEventIDs.insert(eventID)
        nextEvent = EventDisplayPlanner.nextEvent(from: events, dismissedIDs: dismissedEventIDs, now: nowProvider())
    }

    /// Bulk dismiss for the changed-times region: every row gets the same
    /// treatment as its own Dismiss, the events hide everywhere (agenda,
    /// next-event pick, both regions) until they leave the fetch window.
    public func dismissAllTimeChanged() {
        let eventIDs = timeChangedEvents.map(\.id)
        timeChangedEvents = []
        for eventID in eventIDs {
            dismissEvent(eventID)
        }
    }

    /// Acknowledges one changed-times row: the flag leaves, the event keeps
    /// its agenda place. A later shift of the same occurrence flags again.
    public func markTimeChangedAsRead(_ event: CalendarEvent) {
        let key = Self.changeKey(event)
        acknowledgedChangeWindows[key] = (event.startDate, event.endDate)
        timeChangedEvents.removeAll { Self.changeKey($0) == key }
    }

    /// Acknowledges every changed-times row at once, same rule per row.
    public func markAllTimeChangedAsRead() {
        for event in timeChangedEvents {
            acknowledgedChangeWindows[Self.changeKey(event)] = (event.startDate, event.endDate)
        }
        timeChangedEvents = []
    }

    /// Marks every recently-added row as read in one action: rows leave
    /// the region, events keep their agenda place and next-event eligibility.
    public func markAllRecentAsRead() {
        for event in recentEvents {
            readRecentEventIDs.insert(event.id)
        }
        recentEvents = []
    }

    /// Bulk dismiss for the recently-added region: every row gets the same
    /// treatment as its own Dismiss, the events hide everywhere.
    public func dismissAllRecentEvents() {
        let eventIDs = recentEvents.map(\.id)
        for eventID in eventIDs {
            dismissEvent(eventID)
        }
        recentEvents = EventDisplayPlanner.recentEvents(
            firstSeen: firstSeenAt,
            from: horizonEvents.filter { !dismissedEventIDs.contains($0.id) && !readRecentEventIDs.contains($0.id) },
            now: nowProvider(),
            window: recentEventsWindow,
            limit: recentEventsLimit
        )
    }

    /// Marks one recently-added row as read: the event keeps its agenda place
    /// and next-event eligibility, it only leaves the recently-added region.
    /// The read memory outlives the removal, so refreshes cannot re-announce
    /// the same row until its event leaves the fetch window or the app
    /// restarts.
    public func markRecentAsRead(_ eventID: String) {
        readRecentEventIDs.insert(eventID)
        recentEvents = EventDisplayPlanner.recentEvents(
            firstSeen: firstSeenAt,
            from: horizonEvents.filter { !readRecentEventIDs.contains($0.id) },
            now: nowProvider(),
            window: recentEventsWindow,
            limit: recentEventsLimit
        )
    }

    /// Sends the user's RSVP answer for one event through the active store
    /// and refreshes so the badge, menu, and next-event pick up the change.
    /// Returns false when the store rejected the answer.
    @discardableResult
    public func respond(to event: CalendarEvent, status: CalendarEvent.RSVPStatus) async -> Bool {
        let ok = await eventStore.respond(toEventID: event.id, calendarID: event.calendar.id, status: status)
        if ok {
            await refreshEventsAfterAnswer()
        }
        return ok
    }

    /// Same as `respond(to:status:)` for callers that only carry the event
    /// and calendar identifiers (notification action routing).
    @discardableResult
    public func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
        let ok = await eventStore.respond(toEventID: eventID, calendarID: calendarID, status: status)
        if ok {
            await refreshEventsAfterAnswer()
        }
        return ok
    }

    /// `refreshEvents` early-returns while a fetch is in flight, which would
    /// silently drop the post-answer refresh the RSVP flow needs. Requeues
    /// until the in-flight fetch lands so the badge, menu, and next-event
    /// always pick up the stored answer.
    private func refreshEventsAfterAnswer() async {
        for _ in 0..<100 where isLoading {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await refreshEvents()
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

    /// Same bounded-memory rule for read recently-added rows: an ID whose
    /// event left the fetch window is forgotten, so a later reappearance is
    /// announced as recent again.
    private func pruneReadRecentIDs(keeping fetchedEvents: [CalendarEvent]) {
        let currentIDs = Set(fetchedEvents.map { $0.id })
        readRecentEventIDs = readRecentEventIDs.intersection(currentIDs)
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
