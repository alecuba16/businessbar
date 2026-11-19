import Foundation

/// Pure display-policy helper for the event list. Extracted from
/// MeetingManager so date-window, filter, and next-event rules can be
/// unit-tested without a store or UserDefaults side effects.
public enum EventDisplayPlanner {
    /// Fetch window for the current refresh: today, optionally + tomorrow.
    public static func fetchWindow(now: Date = Date(), includeTomorrow: Bool, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        let end = includeTomorrow
            ? calendar.date(byAdding: .day, value: 2, to: startOfToday)!
            : calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        return (startOfToday, end)
    }

    /// Applies dismissed-ID and declined-event visibility rules.
    public static func filter(
        _ events: [CalendarEvent],
        dismissedIDs: Set<String>,
        showDeclined: Bool
    ) -> [CalendarEvent] {
        events.filter { event in
            guard !dismissedIDs.contains(event.id) else { return false }
            if !showDeclined && event.status == .canceled { return false }
            return true
        }
    }

    /// First non-dismissed event that has not ended yet.
    public static func nextEvent(
        from events: [CalendarEvent],
        dismissedIDs: Set<String> = [],
        now: Date = Date()
    ) -> CalendarEvent? {
        events.first { !dismissedIDs.contains($0.id) && $0.endDate > now }
    }

    /// Invitations still waiting for an answer. Already-ended events are
    /// ignored: replying to something in the past is noise, so a stale
    /// pending status on a past event never surfaces.
    public static func pendingInvites(
        from events: [CalendarEvent],
        now: Date = Date()
    ) -> [CalendarEvent] {
        events.filter { $0.myRSVPStatus == .pending && $0.endDate > now }
    }

    /// Events the app first saw within the recency window, newest first.
    /// Drives the menu's recently-added region. Input order is arbitrary;
    /// the returned order follows when each event was first observed.
    public static func recentEvents(
        firstSeen: [String: Date],
        from events: [CalendarEvent],
        now: Date = Date(),
        window: TimeInterval = 24 * 3600,
        limit: Int = 5
    ) -> [CalendarEvent] {
        let cutoff = now.addingTimeInterval(-window)
        return events
            .compactMap { event -> (event: CalendarEvent, seen: Date)? in
                guard let seen = firstSeen[event.id], seen >= cutoff else { return nil }
                return (event, seen)
            }
            .sorted { lhs, rhs in
                if lhs.seen != rhs.seen { return lhs.seen > rhs.seen }
                return lhs.event.startDate < rhs.event.startDate
            }
            .prefix(limit)
            .map(\.event)
    }
}
