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
}
