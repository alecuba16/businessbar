import AppKit
import AppAuth
import BusinessBarCore
import Foundation

// MARK: - Google Calendar REST API adapter

@MainActor
final class GCEventStoreAdapter: EventStoreProtocol {
    private let auth: GoogleAuth

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    // MARK: - EventStoreProtocol

    func requestAccess() async throws -> Bool {
        guard !auth.isAuthenticated else { return true }
        try await auth.signIn()
        return auth.isAuthenticated
    }

    func fetchCalendars() async throws -> [MBCalendar] {
        guard auth.isAuthenticated else { return [] }
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        let data = try await auth.performRequest(url: url)
        return try parseCalendarList(data)
    }

    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] {
        guard auth.isAuthenticated else { return [] }
        var allEvents: [CalendarEvent] = []
        for calendarID in calendars {
            let events = try await fetchEventsForCalendar(calendarID: calendarID, from: startDate, to: endDate)
            allEvents.append(contentsOf: events)
        }
        return allEvents
    }

    // MARK: - Private helpers

    private func fetchEventsForCalendar(calendarID: String, from startDate: Date, to endDate: Date) async throws -> [CalendarEvent] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        guard let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return []
        }

        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedID)/events"
        )!
        components.queryItems = [
            URLQueryItem(name: "timeMin",      value: isoFormatter.string(from: startDate)),
            URLQueryItem(name: "timeMax",      value: isoFormatter.string(from: endDate)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy",      value: "startTime"),
            URLQueryItem(name: "maxResults",   value: "50")
        ]

        guard let url = components.url else { return [] }
        let data = try await auth.performRequest(url: url)

        // We need the calendar object for each event. Fetch it from the list.
        let calendarObjects = try await fetchCalendars()
        let calendarObj = calendarObjects.first(where: { $0.id == calendarID })
            ?? MBCalendar(id: calendarID, title: calendarID, color: "#1a73e8", source: "Google")


        return try parseEventList(data, calendar: calendarObj)
    }

    // MARK: - JSON Parsing

    private func parseCalendarList(_ data: Data) throws -> [MBCalendar] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw GoogleAuthError.apiError("Invalid calendarList response")
        }

        return items.compactMap { item -> MBCalendar? in
            guard let id    = item["id"]      as? String,
                  let title = item["summary"] as? String else { return nil }
            let colorHex = (item["backgroundColor"] as? String) ?? "#1a73e8"
            return MBCalendar(id: id, title: title, color: colorHex, source: "Google")

        }
    }

    private func parseEventList(_ data: Data, calendar: MBCalendar) throws -> [CalendarEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw GoogleAuthError.apiError("Invalid events response")
        }

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime]

        let isoDate = ISO8601DateFormatter()
        isoDate.formatOptions = [.withFullDate]

        return items.compactMap { item -> CalendarEvent? in
            guard let id    = item["id"]      as? String,
                  let title = item["summary"] as? String,
                  let startDict = item["start"] as? [String: Any],
                  let endDict   = item["end"]   as? [String: Any] else { return nil }

            // Google events have either "dateTime" (timed) or "date" (all-day)
            let startDate: Date
            let endDate: Date
            var isAllDay = false

            if let s = (startDict["dateTime"] as? String).flatMap({ isoFull.date(from: $0) }),
               let e = (endDict["dateTime"]   as? String).flatMap({ isoFull.date(from: $0) }) {
                startDate = s
                endDate   = e
            } else if let s = (startDict["date"] as? String).flatMap({ isoDate.date(from: $0) }),
                      let e = (endDict["date"]   as? String).flatMap({ isoDate.date(from: $0) }) {
                startDate = s
                endDate   = e
                isAllDay  = true
            } else {
                return nil
            }

            let location  = item["location"]    as? String
            let notes     = item["description"] as? String

            // Build combined text to scan for meeting links
            let entryPointURIs = (item["conferenceData"] as? [String: Any])
                .flatMap { $0["entryPoints"] as? [[String: Any]] }?
                .compactMap { $0["uri"] as? String }
                .joined(separator: " ") ?? ""

            let linkText = [location, notes, entryPointURIs].compactMap { $0 }.joined(separator: " ")
            let meetingURL = MeetingLinkDetector.detectMeetingLink(in: linkText)

            let organizer = (item["organizer"] as? [String: Any]).flatMap {
                $0["displayName"] as? String ?? $0["email"] as? String
            }
            let attendees = (item["attendees"] as? [[String: Any]])?.compactMap {
                $0["displayName"] as? String ?? $0["email"] as? String
            } ?? []

            let statusRaw = item["status"] as? String
            let status: CalendarEvent.EventStatus = (statusRaw == "cancelled") ? .canceled : .confirmed

            return CalendarEvent(
                id: id,
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes,
                url: meetingURL,
                calendar: calendar,
                organizer: organizer,
                attendees: attendees,
                isAllDay: isAllDay,
                status: status
            )
        }
    }
}
