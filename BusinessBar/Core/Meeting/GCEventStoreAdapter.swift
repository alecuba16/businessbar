import AppKit
import AppAuth
import BusinessBarCore
import Foundation

// MARK: - Google Calendar REST API adapter

@MainActor
final class GCEventStoreAdapter: EventStoreProtocol {
    struct Dependencies {
        var isAuthenticated: () -> Bool
        var signIn: () async throws -> Void
        var request: (URL) async throws -> Data
        var requestJSON: (URL, String, Data) async throws -> Data
    }
    private let dependencies: Dependencies

    convenience init(auth: GoogleAuth) {
        self.init(dependencies: Dependencies(
            isAuthenticated: { auth.isAuthenticated },
            signIn: { try await auth.signIn() },
            request: { try await auth.performRequest(url: $0) },
            requestJSON: { url, method, body in
                try await auth.performJSONRequest(url: url, method: method, body: body)
            }
        ))
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - EventStoreProtocol

    func requestAccess() async throws -> Bool {
        guard !dependencies.isAuthenticated() else { return true }
        try await dependencies.signIn()
        return dependencies.isAuthenticated()
    }

    func fetchCalendars() async throws -> [MBCalendar] {
        guard dependencies.isAuthenticated() else { return [] }
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        let data = try await dependencies.request(url)
        return try parseCalendarList(data)
    }

    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] {
        guard dependencies.isAuthenticated() else { return [] }
        var allEvents: [CalendarEvent] = []
        for calendarID in calendars {
            let events = try await fetchEventsForCalendar(calendarID: calendarID, from: startDate, to: endDate)
            allEvents.append(contentsOf: events)
        }
        return allEvents
    }

    // MARK: - RSVP

    @discardableResult
    func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
        guard dependencies.isAuthenticated() else { return false }
        let googleStatus: String
        switch status {
        case .accepted: googleStatus = "accepted"
        case .declined: googleStatus = "declined"
        case .tentative: googleStatus = "tentative"
        case .pending, .unknown: return false
        }

        // The PATCH body lists only the caller's own attendee entry with
        // the new responseStatus, so the server updates just that response.
        guard let encodedCalendar = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedEvent = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return false
        }
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendar)/events/\(encodedEvent)?sendUpdates=none")!

        let body: [String: Any] = [
            "attendees": [["self": true, "responseStatus": googleStatus]],
            "attendeesOmitted": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }

        do {
            _ = try await dependencies.requestJSON(url, "PATCH", data)
            return true
        } catch {
            AppLogger.error("RSVP reply failed: \(error.localizedDescription)", category: "Calendar")
            return false
        }
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
        let data = try await dependencies.request(url)

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

            // Google marks the signed-in user's own attendee entry with
            // "self": true; its responseStatus is their RSVP state.
            let selfAttendee = (item["attendees"] as? [[String: Any]])?
                .first { ($0["self"] as? Bool) == true }
            let rsvpStatus: CalendarEvent.RSVPStatus
            switch selfAttendee?["responseStatus"] as? String {
            case "needsAction": rsvpStatus = .pending
            case "accepted": rsvpStatus = .accepted
            case "declined": rsvpStatus = .declined
            case "tentative": rsvpStatus = .tentative
            default: rsvpStatus = .accepted
            }

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
                status: status,
                myRSVPStatus: rsvpStatus
            )
        }
    }
}
