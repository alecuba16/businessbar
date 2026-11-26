import AppKit
import EventKit
import Foundation
@testable import BusinessBarCore

/// Fixture for the answer-while-fetching case: the first fetch parks on an
/// async continuation until `openGate` resumes it. Parking must suspend, not
/// block: EventStoreProtocol is main-actor bound, so a semaphore wait inside
/// fetchEvents would freeze the actor and the scenario poll with it.
@MainActor
private final class SlowAnswerEventStore: EventStoreProtocol {
    private var parkedFetches: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var storedEvents: [CalendarEvent] = []
    private var storedCalendars: [MBCalendar] = []
    var receivedRSVPs: [(eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus)] = []

    func seed(_ events: [CalendarEvent], calendars: [MBCalendar]) {
        storedEvents = events
        storedCalendars = calendars
    }

    /// Resumes every parked fetch and stops parking later ones, so the
    /// post-answer refresh returns immediately and the suite cannot stall.
    func openGate() {
        opened = true
        let waiters = parkedFetches
        parkedFetches.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func requestAccess() async throws -> Bool { true }

    func fetchCalendars() async throws -> [MBCalendar] {
        storedCalendars
    }

    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] {
        if !opened {
            await withCheckedContinuation { continuation in
                parkedFetches.append(continuation)
            }
        }
        return storedEvents
    }

    func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
        receivedRSVPs.append((eventID, calendarID, status))
        return true
    }
}

@MainActor
private final class CoverageEventStore: EventStoreProtocol {
    enum Failure: Error { case unavailable }
    var permission = true
    var fail = false
    var calendars: [MBCalendar] = []
    var events: [CalendarEvent] = []
    var requests: [(Date, Date, [String])] = []
    var duringFetch: (() async -> Void)?
    /// RSVP answers received through respond(toEventID:calendarID:status:).
    var receivedRSVPs: [(eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus)] = []
    var respondResult = true

    func requestAccess() async throws -> Bool {
        if fail { throw Failure.unavailable }
        return permission
    }

    func fetchCalendars() async throws -> [MBCalendar] {
        if fail { throw Failure.unavailable }
        return calendars
    }

    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] {
        requests.append((startDate, endDate, calendars))
        if let duringFetch { await duringFetch() }
        if fail { throw Failure.unavailable }
        return events
    }

    func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
        receivedRSVPs.append((eventID, calendarID, status))
        return respondResult
    }
}

@MainActor
private final class CoverageCalendarBackend: CalendarStoreBackend {
    enum Failure: Error { case unavailable }
    var hasAccess = false
    var grant = true
    var fail = false
    var refreshes = 0
    var calendarReads = 0
    /// Event the RSVP path finds through event(withID:).
    var storedEvents: [String: EKEvent] = [:]
    var saveResults: [String: Bool] = [:]
    var saveCalls: [String] = []
    /// When set, save(_:) throws instead of returning.
    var saveError: Error?
    func requestAccess() async throws -> Bool {
        if fail { throw Failure.unavailable }
        return grant
    }
    func refreshSources() { refreshes += 1 }
    func calendars() -> [EKCalendar] { calendarReads += 1; return [] }
    func events(from startDate: Date, to endDate: Date, calendars: [EKCalendar]) -> [EKEvent] { [] }
    func event(withID eventID: String) -> EKEvent? { storedEvents[eventID] }
    @discardableResult
    func save(_ event: EKEvent) throws -> Bool {
        saveCalls.append(event.eventIdentifier ?? "")
        if let saveError { throw saveError }
        if let forced = saveResults[event.eventIdentifier ?? ""] { return forced }
        return true
    }
}

/// Coverage seam for the native store's access request: answers the real
/// `requestFullAccessToEvents` completion without a TCC prompt, so headless
/// hosts (CI) cannot hang waiting for a grant nobody can give. The backend's
/// continuation body still executes unchanged.
private final class PromptFreeEventStore: EKEventStore {
    var accessAnswer: (Bool, Error?) = (true, nil)

    override func requestFullAccessToEvents(completion: @escaping (Bool, (any Error)?) -> Void) {
        completion(accessAnswer.0, accessAnswer.1)
    }
}

@MainActor
enum CoreMeetingUtilitiesScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        let scenarios: [(String, () throws -> Void)] = [
            ("planner/models", { try plannerAndModels(context) }),
            ("links", { try links(context) }),
            ("utilities", { try utilities(context) })
        ]
        for (name, scenario) in scenarios {
            do { try scenario() }
            catch { failures.append("\(name): \(error)") }
        }
        do { try await adapter(context) }
        catch { failures.append("calendar adapter: \(error)") }
        do { try await manager(context) }
        catch { failures.append("meeting manager: \(error)") }
        do { try await rsvp(context) }
        catch { failures.append("rsvp flow: \(error)") }
        do { try await timeChanges(context) }
        catch { failures.append("time changes: \(error)") }
        do { try await timeChangePastAndRecurrence(context) }
        catch { failures.append("time changes past and recurrence: \(error)") }
        do { try await recentBulkActions(context) }
        catch { failures.append("recent bulk actions: \(error)") }
        do { try await recentAndTimeChangeOverlap(context) }
        catch { failures.append("recent and time-change overlap: \(error)") }
        do { try ekParticipantMapping(context) }
        catch { failures.append("participant mapping: \(error)") }
        do { try await ekRespond(context) }
        catch { failures.append("ek respond: \(error)") }
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private static let instant = Date(timeIntervalSince1970: 1_772_964_000)
    private static let calendar = MBCalendar(id: "work", title: "Work", color: "#123456", source: "Fixture")

    private static func event(_ id: String, start: TimeInterval = -60, end: TimeInterval = 600, status: CalendarEvent.EventStatus = .confirmed, occurrence: Date? = nil, recurring: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, startDate: instant.addingTimeInterval(start), endDate: instant.addingTimeInterval(end), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Organizer", attendees: ["Attendee"], status: status, occurrenceDate: occurrence, isRecurring: recurring)
    }

    private static func plannerAndModels(_ context: CoverageContext) throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z")!
        let today = EventDisplayPlanner.fetchWindow(now: spring, includeTomorrow: false, calendar: gregorian)
        let tomorrow = EventDisplayPlanner.fetchWindow(now: spring, includeTomorrow: true, calendar: gregorian)
        try context.equal(today.end.timeIntervalSince(today.start), 23 * 3600, "DST fetch window uses calendar day")
        try context.equal(tomorrow.end.timeIntervalSince(today.end), 24 * 3600, "Tomorrow adds one calendar day")
        // The horizon widens the window past the legacy two days; the
        // includeTomorrow floor keeps the legacy minimums untouched. Day
        // components, not elapsed time: March 8 is the spring-forward
        // date in this zone, so 14 calendar days is one wall-clock hour
        // short.
        let horizon = EventDisplayPlanner.fetchWindow(now: spring, includeTomorrow: false, horizonDays: 14, calendar: gregorian)
        try context.equal(gregorian.dateComponents([.day], from: horizon.start, to: horizon.end).day, 14, "Horizon extends the window in calendar days")
        try context.equal(horizon.start, today.start, "Horizon window keeps the start of today")
        let flooredHorizon = EventDisplayPlanner.fetchWindow(now: spring, includeTomorrow: true, horizonDays: 1, calendar: gregorian)
        try context.equal(gregorian.dateComponents([.day], from: flooredHorizon.start, to: flooredHorizon.end).day, 2, "Tomorrow floor survives a shorter horizon")
        let ended = event("ended", end: 0)
        let live = event("live")
        let declined = event("declined", status: .canceled)
        try context.equal(EventDisplayPlanner.nextEvent(from: [ended, live], now: instant)?.id, "live", "End boundary is excluded")
        try context.expect(EventDisplayPlanner.nextEvent(from: [live], dismissedIDs: ["live"], now: instant) == nil, "Dismissal wins over ongoing event")
        try context.equal(EventDisplayPlanner.filter([live, declined], dismissedIDs: [], showDeclined: false).map(\.id), ["live"], "Declined events hidden")
        try context.equal(EventDisplayPlanner.filter([live, declined], dismissedIDs: ["live"], showDeclined: true).map(\.id), ["declined"], "Visibility does not restore dismissed event")
        let ownDecline = CalendarEvent(id: "own-decline", title: "own-decline", startDate: instant.addingTimeInterval(-60), endDate: instant.addingTimeInterval(600), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Boss", attendees: ["Boss"], myRSVPStatus: .declined)
        try context.equal(EventDisplayPlanner.filter([live, ownDecline], dismissedIDs: [], showDeclined: false).map(\.id), ["live"], "Declined RSVP hides the event")
        try context.equal(EventDisplayPlanner.filter([ownDecline], dismissedIDs: [], showDeclined: true).map(\.id), ["own-decline"], "Declined RSVP visible with the toggle on")
        let pendingLive = CalendarEvent(id: "pending-live", title: "pending-live", startDate: instant.addingTimeInterval(-60), endDate: instant.addingTimeInterval(600), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Boss", attendees: ["Boss"], myRSVPStatus: .pending)
        let pendingEnded = CalendarEvent(id: "pending-ended", title: "pending-ended", startDate: instant.addingTimeInterval(-4200), endDate: instant.addingTimeInterval(-60), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Boss", attendees: ["Boss"], myRSVPStatus: .pending)
        try context.equal(EventDisplayPlanner.pendingInvites(from: [pendingLive, pendingEnded], now: instant).map(\.id), ["pending-live"], "Ended invitations stay out of the pending set")
        let recentSoon = event("recent-soon", start: 3600, end: 4200)
        let recentOld = event("recent-old", start: 7200, end: 7800)
        let firstSeen: [String: Date] = [
            recentSoon.id: instant.addingTimeInterval(-3600),
            recentOld.id: instant.addingTimeInterval(-48 * 3600)
        ]
        try context.equal(EventDisplayPlanner.recentEvents(firstSeen: firstSeen, from: [recentSoon, recentOld], now: instant).map(\.id), ["recent-soon"], "Only events first seen inside the window are recent")
        try context.equal(EventDisplayPlanner.recentEvents(firstSeen: [:], from: [recentSoon], now: instant).map(\.id), [], "Events without first-seen memory are not recent")
        try context.equal(live.duration, 660, "Model duration retains start and end")
        try context.equal(live.organizer, "Organizer", "Organizer retained")
        try context.equal(live.attendees, ["Attendee"], "Attendees retained")
        try context.expect(!event("old", start: -1e9, end: -1e8).isHappening, "Past model is not happening")
        let current = CalendarEvent(id: "current", title: "Current", startDate: .distantPast, endDate: .distantFuture, location: nil, notes: nil, url: nil, calendar: calendar, organizer: nil, attendees: [], isAllDay: true, status: .tentative)
        try context.expect(current.isHappening && current.isAllDay, "Ongoing all-day model")
        try context.equal(try JSONDecoder().decode(MBCalendar.self, from: JSONEncoder().encode(calendar)), calendar, "Calendar Codable roundtrip")
        for status in [CalendarEvent.EventStatus.none, .tentative, .confirmed, .canceled] {
            try context.equal(try JSONDecoder().decode(CalendarEvent.EventStatus.self, from: JSONEncoder().encode(status)), status, "Status roundtrip")
        }
        try context.equal(Set([live, live]).count, 1, "Event identity/hash agreement")
    }

    private static func links(_ context: CoverageContext) throws {
        let cases: [(MeetingService, String)] = [
            (.zoom, "https://company.zoom.us/j/123"), (.googleMeet, "https://meet.google.com/abc-defg-hij"),
            (.microsoftTeams, "https://teams.microsoft.com/l/meetup-join/123"), (.webex, "https://company.webex.com/meet/room"),
            (.jitsi, "https://meet.jit.si/room"), (.slack, "https://company.slack.com/huddle/room"),
            (.discord, "https://discord.gg/room"), (.skype, "https://join.skype.com/room"),
            (.bluejeans, "https://bluejeans.com/123"), (.gotomeeting, "https://gotomeeting.com/123"),
            (.hangouts, "https://hangouts.google.com/call/room"), (.whereby, "https://whereby.com/room"),
            (.around, "https://meet.around.co/room"), (.meet, "https://meet.example.com/room"),
            (.chime, "https://chime.aws/123"), (.ringcentral, "https://meetings.ringcentral.com/j/123"),
            (.eight_by_eight, "https://8x8.vc/room"), (.facetime, "facetime://person"),
            (.phone, "tel:+123-456"), (.generic, "https://example.com/meeting")
        ]
        try context.equal(cases.count, MeetingService.allCases.count, "Every service has a contract fixture")
        for (service, link) in cases {
            let regex = try NSRegularExpression(pattern: service.pattern, options: .caseInsensitive)
            try context.expect(regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)) != nil, "Service pattern recognizes \(service.rawValue)")
            try context.equal(MeetingLinkDetector.detectMeetingLink(in: "Join \(link) now")?.absoluteString, link, "Detect \(service.rawValue)")
        }
        try context.expect(MeetingLinkDetector.detectMeetingLink(in: "No meeting 🦊") == nil, "Unicode prose has no meeting")
        try context.equal(MeetingLinkDetector.detectMeetingLink(in: "https://example.com/path https://zoom.us/j/123")?.host, "zoom.us", "Specific service beats generic URL")
        let linked = CalendarEvent(id: "linked", title: "Linked", startDate: instant, endDate: instant, location: "https://meet.google.com/abc-defg-hij", notes: "https://example.com/other", url: URL(string: "https://zoom.us/j/123"), calendar: calendar, organizer: nil, attendees: [])
        try context.equal(linked.meetingLink?.host, "zoom.us", "Event model delegates URL detection")
    }

    private static func utilities(_ context: CoverageContext) throws {
        for (seconds, expected) in [(-1.0, "passed"), (0, "now"), (59, "now"), (60, "in 1m"), (3599, "in 59m"), (3600, "in 1h"), (86399, "in 23h"), (86400, "in 1d")] {
            try context.equal(instant.addingTimeInterval(seconds).relativeString(now: instant), expected, "Relative date boundary \(seconds)")
        }
        for (seconds, expected) in [(-1.0, "ended"), (0, "0m"), (59, "0m"), (60, "1m"), (3600, "1h 0m"), (7500, "2h 5m")] {
            try context.equal(instant.timeRemaining(until: instant.addingTimeInterval(seconds)), expected, "Remaining date boundary \(seconds)")
        }
        try context.equal("🧑🏽‍💻abc".truncated(to: 2, trailing: "…"), "🧑🏽‍💻…", "Truncation preserves composed grapheme")
        try context.equal("abc".truncated(to: -1), "...", "Negative limit does not trap")
        try context.equal("abc".truncated(to: 0, trailing: ""), "", "Zero prefix supports empty trailer")
        try context.equal("short".truncated(to: 5), "short", "Exact length unchanged")
        try context.equal("<b>Hello</b> &amp; <i>world</i>".stripHTML(), "Hello & world", "HTML tags and entities decoded")
        try context.equal("".stripHTML(), "", "Empty HTML remains empty")
        try context.equal(NSColor(deviceRed: 1, green: 0.5, blue: 0, alpha: 1).hexString, "#FF7F00", "Color components truncate to hex")
        try context.equal(NSColor.white.hexString, "#FFFFFF", "White converts to RGB")
        try context.equal(Constants.DefaultValues.badgePollInterval, 3, "Polling default contract")
        try context.expect(Constants.Defaults.featureCalendar != Constants.Defaults.featureNoSleep, "Feature preference keys independent")
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        for count in [1, 100] {
            let badge = image.withBadge(count: count)
            try context.equal(badge.size, NSSize(width: 18, height: 18), "Badge icon dimensions")
            try context.expect(!badge.isTemplate && badge.tiffRepresentation != nil, "Badge renders colored representation")
        }
        let gray: NSImage = image.grayscale()
        let optionalGray: NSImage? = image.grayscale()
        try context.equal(gray.size, image.size, "Grayscale preserves dimensions")
        try context.expect(optionalGray != nil && optionalGray?.isTemplate == false, "Optional grayscale remains colored-image rendering")
        let alphaGray = image.grayscalePreservingAlpha()
        try context.expect(!alphaGray.isTemplate, "Alpha grayscale is not template")
        let inverted = image.inverted()
        try context.equal(inverted.size, image.size, "Inversion preserves dimensions")
        let tint = image.tinted(with: .blue)
        try context.expect(!tint.isTemplate && tint.tiffRepresentation != nil, "Tint produces actual bitmap")
        let resized = image.resized(to: NSSize(width: 4, height: 6))
        try context.equal(resized.size, NSSize(width: 4, height: 6), "Resize target dimensions")
        try context.expect(resized.tiffRepresentation != nil, "Resize draws content")
        try context.expect(image.adaptedForAppearance(NSAppearance(named: .aqua)!) === image, "Light mode retains source")
        try context.equal(image.adaptedForAppearance(NSAppearance(named: .darkAqua)!).size, image.size, "Dark mode inversion dimensions")
        let grayPixel = try pixel(gray, context)
        try context.expect(abs(grayPixel.redComponent - grayPixel.greenComponent) < 0.04 && abs(grayPixel.greenComponent - grayPixel.blueComponent) < 0.04, "Grayscale removes color saturation")
        let invertedPixel = try pixel(inverted, context)
        try context.expect(invertedPixel.redComponent < 0.1 && invertedPixel.greenComponent > 0.9 && invertedPixel.blueComponent > 0.9, "Red inversion renders cyan")
        let sourcePixel = try pixel(image, context)
        let tintedPixel = try pixel(tint, context)
        let tintDescription = "source=\(sourcePixel), tinted=\(tintedPixel)"
        try context.expect(tintedPixel.blueComponent > sourcePixel.blueComponent + 0.2 && tintedPixel.redComponent < sourcePixel.redComponent - 0.1, "Blue tint changes source channels: \(tintDescription)")
        try context.expect(tintedPixel.redComponent > tintedPixel.greenComponent && tintedPixel.blueComponent > tintedPixel.greenComponent, "Half-alpha tint retains red and adds blue: \(tintDescription)")
        try context.expect(abs(tintedPixel.alphaComponent - sourcePixel.alphaComponent) < 0.02, "Source-atop tint preserves source alpha: \(tintDescription)")
        let empty = NSImage(size: .zero)
        let emptyGray: NSImage = empty.grayscale()
        try context.expect(emptyGray === empty, "Missing CG image preserves source")
        try context.expect(empty.grayscalePreservingAlpha() === empty && empty.inverted() === empty, "Transforms safely retain unrenderable source")
        let emptyOptionalGray: NSImage? = empty.grayscale()
        try context.expect(emptyOptionalGray == nil, "Optional grayscale reports unrenderable image")
        try context.equal(NSColor(patternImage: image).hexString, "#000000", "Non-RGB pattern falls back to black")
    }

    private static func pixel(_ image: NSImage, _ context: CoverageContext) throws -> NSColor {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
            throw CoverageContext.Failure(description: "Expected rendered RGB pixel")
        }
        try context.expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Rendered image has pixels")
        return color
    }

    private static func adapter(_ context: CoverageContext) async throws {
        let backend = CoverageCalendarBackend()
        let adapter = EKEventStoreAdapter(backend: backend)
        let inaccessible = try await adapter.fetchCalendars()
        try context.expect(inaccessible.isEmpty && backend.calendarReads == 0, "Denied access never reads calendars")
        let inaccessibleEvents = try await adapter.fetchEvents(from: instant, to: instant, calendars: ["work"])
        try context.expect(inaccessibleEvents.isEmpty, "Denied access never reads events")
        backend.grant = false
        try await context.expectThrowsAsync("Denied calendar grant throws") { _ = try await adapter.requestAccess() }
        try context.equal(backend.refreshes, 0, "Denied grant does not rebuild store")
        backend.fail = true
        try await context.expectThrowsAsync("Calendar permission error propagates") { _ = try await adapter.requestAccess() }
        backend.fail = false
        backend.grant = true
        let granted = try await adapter.requestAccess()
        try context.expect(granted && backend.refreshes == 1, "Granted access refreshes delegated sources once")
        backend.hasAccess = true
        let emptyCalendars = try await adapter.fetchCalendars()
        try context.expect(emptyCalendars.isEmpty, "Authorized empty calendars")
        let emptyEvents = try await adapter.fetchEvents(from: instant, to: instant, calendars: ["work"])
        try context.expect(emptyEvents.isEmpty && backend.calendarReads == 2, "No matching calendars avoids event query")
    }

    private static func manager(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("meeting")
        defaults.set(false, forKey: Constants.Defaults.featureCalendar)
        let notifications = NotificationCenter()
        let store = CoverageEventStore()
        store.calendars = [calendar]
        var now = instant
        let manager = MeetingManager(eventStore: store, nowProvider: { now }, defaults: defaults, notificationCenter: notifications)
        await Task.yield()
        try context.expect(manager.events.isEmpty && manager.calendars.isEmpty, "Disabled manager starts empty")
        await manager.loadCalendars()
        await manager.refreshEvents()
        try context.expect(store.requests.isEmpty, "Disabled feature does not query events")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        try await wait(context, "Feature-on notification loads calendars") { manager.calendars == [calendar] }
        await manager.loadCalendars()
        try context.equal(manager.calendars, [calendar], "Manager loads injected calendars")
        let permitted = try await manager.requestAccess()
        try context.expect(permitted, "Manager forwards permission result")
        store.permission = false
        let denied = try await manager.requestAccess()
        try context.expect(!denied, "Manager forwards false permission result")
        store.fail = true
        try await context.expectThrowsAsync("Permission errors propagate") { _ = try await manager.requestAccess() }
        await manager.loadCalendars()
        try context.equal(manager.calendars, [calendar], "Calendar failure retains previous list")
        store.fail = false
        let first = event("first")
        let later = event("later", start: 300, end: 900)
        let canceled = event("canceled", start: 200, status: .canceled)
        let old = event("ended", start: -300, end: 0)
        store.events = [later, canceled, first, old]
        await manager.refreshEvents()
        try context.equal(manager.events.map(\.id), ["ended", "first", "later"], "Manager sorts and hides canceled events")
        try context.equal(manager.nextEvent?.id, "first", "Manager uses injected clock for next event")
        try context.equal(store.requests.last?.2, ["work"], "Missing selection falls back to loaded calendar IDs")
        try context.expect(!manager.isLoading, "Refresh clears loading state")
        manager.dismissEvent("first")
        try context.equal(manager.nextEvent?.id, "later", "Dismissal advances cached next event")
        await manager.refreshEvents()
        try context.expect(!manager.events.contains { $0.id == "first" }, "Dismissed event excluded on refresh")
        store.events = [later]
        await manager.refreshEvents()
        store.events = [first, later]
        await manager.refreshEvents()
        try context.equal(manager.nextEvent?.id, "first", "Dismissed IDs pruned when outside fetched window")

        // Recently-added rows can be marked as read: the row leaves the
        // region while the event keeps its agenda and next-event place, and
        // the read memory survives refreshes until the event leaves the
        // fetch window or the feature turns off.
        try context.equal(manager.recentEvents.map(\.id), ["first", "later"], "Seen events populate the recent region")
        manager.markRecentAsRead("first")
        try context.equal(manager.recentEvents.map(\.id), ["later"], "Marked row leaves the recent region")
        try context.equal(manager.nextEvent?.id, "first", "Read row keeps its agenda place and next-event eligibility")
        await manager.refreshEvents()
        try context.equal(manager.recentEvents.map(\.id), ["later"], "Read memory survives refresh")
        store.events = [later]
        await manager.refreshEvents()
        store.events = [first, later]
        await manager.refreshEvents()
        try context.equal(manager.recentEvents.map(\.id), ["first", "later"], "Read ID pruned once its event leaves the fetch window")

        // Declined events neither display nor change-track: the filter runs
        // before tracking memories update, so their windows never land in
        // lastSeenWindows and a later time move has nothing to compare.
        defaults.set(false, forKey: Constants.Defaults.showDeclinedEvents)
        let declineFixed = CalendarEvent(id: "declined-fixed", title: "Declined", startDate: instant.addingTimeInterval(3600), endDate: instant.addingTimeInterval(4200), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Boss", attendees: ["Boss"], myRSVPStatus: .declined)
        let normalFixed = event("normal-fixed", start: 3600, end: 4200)
        store.events = [declineFixed, normalFixed]
        await manager.refreshEvents()
        try context.equal(manager.events.map(\.id), ["normal-fixed"], "Declined event hidden from the agenda")
        try context.equal(manager.recentEvents.map(\.id), ["normal-fixed"], "Declined event never announced as recent")
        try context.expect(manager.timeChangedEvents.isEmpty, "First fetch seeds nothing to compare against")
        let declineMoved = CalendarEvent(id: "declined-fixed", title: "Declined", startDate: instant.addingTimeInterval(4000), endDate: instant.addingTimeInterval(4600), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Boss", attendees: ["Boss"], myRSVPStatus: .declined)
        store.events = [declineMoved, normalFixed]
        await manager.refreshEvents()
        try context.equal(manager.events.map(\.id), ["normal-fixed"], "Declined event stays hidden after its own time move")
        try context.expect(manager.timeChangedEvents.isEmpty, "Declined event's time move produces no change flag")
        // Hand the shared fixture back so the downstream tick and
        // refresh-failure checks observe the same agenda they were
        // written against.
        store.events = [first, later]
        await manager.refreshEvents()

        now = instant.addingTimeInterval(650)
        manager.recalculateNextEvent()
        try context.equal(manager.nextEvent?.id, "later", "Tick excludes ended event")
        store.fail = true
        await manager.refreshEvents()
        try context.expect(!manager.isLoading && manager.events.count == 2, "Failed refresh retains events and clears loading")
        store.fail = false
        defaults.set(try JSONEncoder().encode([String]()), forKey: Constants.Defaults.selectedCalendars)
        let requestCount = store.requests.count
        await manager.refreshEvents()
        try context.expect(manager.events.isEmpty && manager.nextEvent == nil && store.requests.count == requestCount, "Explicit empty selection never queries store")
        defaults.set(Data("invalid".utf8), forKey: Constants.Defaults.selectedCalendars)
        defaults.set(true, forKey: Constants.Defaults.showDeclinedEvents)
        store.events = [canceled]
        await manager.refreshEvents()
        try context.equal(manager.events.map(\.id), ["canceled"], "Malformed selection falls back and declined visibility applies")
        defaults.set(false, forKey: Constants.Defaults.showTomorrowEvents)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let outside = CalendarEvent(id: "tomorrow", title: "Tomorrow", startDate: tomorrow, endDate: tomorrow.addingTimeInterval(60), location: nil, notes: nil, url: nil, calendar: calendar, organizer: nil, attendees: [])
        store.events = [first, outside]
        await manager.refreshEvents()
        try context.equal(manager.events.map(\.id), ["first"], "Today-only mode removes tomorrow even if backend returns it")
        let beforeReentry = store.requests.count
        store.duringFetch = { await manager.refreshEvents() }
        await manager.refreshEvents()
        store.duringFetch = nil
        try context.equal(store.requests.count, beforeReentry + 1, "Refresh ignores reentrant request while loading")
        defaults.set(false, forKey: Constants.Defaults.featureCalendar)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        try await wait(context, "Feature-off notification clears events and calendars") { manager.events.isEmpty && manager.nextEvent == nil && manager.calendars.isEmpty }
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        try await wait(context, "Feature-on notification reloads calendars and events") { manager.events.map(\.id) == ["first"] }
        let beforeEventNotification = store.requests.count
        notifications.post(name: .EKEventStoreChanged, object: nil)
        try await wait(context, "Injected event-store notification refreshes") { store.requests.count > beforeEventNotification && !manager.isLoading }
        let beforeMidnight = store.requests.count
        now = now.addingTimeInterval(86400)
        manager.recalculateNextEvent()
        try await wait(context, "Day rollover triggers fetch") { store.requests.count > beforeMidnight && !manager.isLoading }
        defaults.removeObject(forKey: Constants.Defaults.featureCalendar)
        let beforeDefaultFeature = store.requests.count
        await manager.refreshEvents()
        try context.expect(store.requests.count > beforeDefaultFeature, "Missing feature preference defaults to enabled")
        defaults.set(false, forKey: Constants.Defaults.featureCalendar)
        await manager.refreshEvents()
        await manager.loadCalendars()
        try context.expect(manager.events.isEmpty && manager.calendars.isEmpty, "Explicit refresh observes disabled preference")
    }

    private static func rsvp(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("meeting-rsvp")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(try JSONEncoder().encode([calendar.id]), forKey: Constants.Defaults.selectedCalendars)
        let notifications = NotificationCenter()
        let store = CoverageEventStore()
        store.calendars = [calendar]
        let manager = MeetingManager(eventStore: store, nowProvider: { instant }, defaults: defaults, notificationCenter: notifications)
        await Task.yield()

        var newEventPosts: [[CalendarEvent]] = []
        var pendingPosts: [[CalendarEvent]] = []
        let newObserver = notifications.publisher(for: .businessBarNewEventsAppeared).sink { note in
            if let events = note.userInfo?["events"] as? [CalendarEvent] { newEventPosts.append(events) }
        }
        let pendingObserver = notifications.publisher(for: .businessBarPendingRSVPsAppeared).sink { note in
            if let events = note.userInfo?["events"] as? [CalendarEvent] { pendingPosts.append(events) }
        }
        defer { newObserver.cancel(); pendingObserver.cancel() }

        let invited = CalendarEvent(id: "invited", title: "Invited", startDate: instant.addingTimeInterval(600), endDate: instant.addingTimeInterval(1200), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Boss", attendees: ["Boss", "Me"], myRSVPStatus: .pending)
        let personal = CalendarEvent(id: "personal", title: "Personal", startDate: instant.addingTimeInterval(300), endDate: instant.addingTimeInterval(900), location: nil, notes: nil, url: nil, calendar: calendar, organizer: nil, attendees: [], myRSVPStatus: .accepted)

        store.events = [invited, personal]
        await manager.refreshEvents()
        try context.equal(manager.pendingRSVPEvents.map(\.id), ["invited"], "Only pending RSVP events surface")
        try context.equal(newEventPosts.count, 1, "First refresh posts newly seen events")
        try context.equal(newEventPosts.last?.map(\.id).sorted(), ["invited", "personal"], "Both events are new on first refresh")
        try context.equal(pendingPosts.count, 1, "First refresh posts pending invites")

        store.events = [invited, personal]
        await manager.refreshEvents()
        try context.equal(newEventPosts.count, 1, "Known events are not re-announced")
        try context.equal(pendingPosts.count, 2, "Unanswered invite re-announced on every refresh")

        let late = CalendarEvent(id: "late", title: "Late", startDate: instant.addingTimeInterval(1500), endDate: instant.addingTimeInterval(2000), location: nil, notes: nil, url: nil, calendar: calendar, organizer: nil, attendees: [], myRSVPStatus: .accepted)
        store.events = [invited, personal, late]
        await manager.refreshEvents()
        try context.equal(newEventPosts.last?.map(\.id), ["late"], "Only the new event is announced")

        store.respondResult = true
        let accepted = await manager.respond(to: invited, status: .accepted)
        try context.expect(accepted, "Successful answer returns true")
        try context.equal(store.receivedRSVPs.map(\.0), ["invited"], "Answer reaches the store")
        try context.equal(store.receivedRSVPs.map(\.2), [.accepted], "Status passes through unchanged")

        store.respondResult = false
        let failed = await manager.respond(toEventID: "invited", calendarID: calendar.id, status: .declined)
        try context.expect(!failed, "Rejected answer returns false")
        try context.equal(store.receivedRSVPs.map(\.2), [.accepted, .declined], "Both answer variants reach the store")

        // Answer while a fetch is in flight: refreshEventsAfterAnswer waits
        // out the in-flight refresh instead of dropping the post-answer one,
        // so the stored answer lands in the published state. The first fetch
        // parks on a continuation (the actor stays responsive), then a side
        // task holds the gate open after a moment so the parked fetch lands
        // while the answer's wait loop is running.
        let slowStore = SlowAnswerEventStore()
        slowStore.seed([invited, personal], calendars: [calendar])
        let slowManager = MeetingManager(eventStore: slowStore, nowProvider: { instant }, defaults: defaults, notificationCenter: notifications)
        var observedInFlight = false
        let slowRefresh = Task { await slowManager.refreshEvents() }
        for _ in 0..<400 where !observedInFlight {
            observedInFlight = slowManager.isLoading
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try context.expect(observedInFlight, "Fetch is in flight while the answer arrives")
        slowStore.seed([
            CalendarEvent(id: invited.id, title: invited.title, startDate: invited.startDate, endDate: invited.endDate, location: invited.location, notes: invited.notes, url: invited.url, calendar: invited.calendar, organizer: invited.organizer, attendees: invited.attendees, myRSVPStatus: .accepted),
            personal
        ], calendars: [calendar])
        let gateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            slowStore.openGate()
        }
        let slowAnswer = await slowManager.respond(to: invited, status: .accepted)
        try context.expect(slowAnswer, "Answer during in-flight fetch returns true")
        try context.equal(slowStore.receivedRSVPs.map(\.0), [invited.id], "Slow store received the answer while fetching")
        _ = await slowRefresh.value
        _ = await gateTask.value
        try context.expect(slowManager.isLoading == false, "In-flight refresh completed after the gate opened")
        try await wait(context, "Post-answer refresh picks up the stored answer") {
            slowManager.pendingRSVPEvents.isEmpty
        }
        try context.equal(slowManager.pendingRSVPEvents.count, 0, "Answered invite left the pending set after the wait")
    }

    private static func timeChanges(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("meeting-time-changes")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(try JSONEncoder().encode([calendar.id]), forKey: Constants.Defaults.selectedCalendars)
        let notifications = NotificationCenter()
        let store = CoverageEventStore()
        store.calendars = [calendar]
        let manager = MeetingManager(eventStore: store, nowProvider: { instant }, defaults: defaults, notificationCenter: notifications)
        await Task.yield()

        var changedPosts: [[CalendarEvent]] = []
        let changedObserver = notifications.publisher(for: .businessBarEventTimesChanged).sink { note in
            if let events = note.userInfo?["events"] as? [CalendarEvent] { changedPosts.append(events) }
        }
        defer { changedObserver.cancel() }

        // First fetch: everything is first-seen, nothing counts as changed.
        let stable = event("stable", start: 3600, end: 4200)
        let moving = event("moving", start: 7200, end: 7800)
        store.events = [stable, moving]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "First fetch has no change baseline")
        try context.equal(changedPosts.count, 0, "No time-change notification on first sight")
        // The recent region now suppresses change flags for rows still inside
        // it, so clear the region before exercising the raw flagging rules.
        manager.markAllRecentAsRead()

        // Same window again: still nothing.
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Unmoved events stay out of the changed set")
        try context.equal(changedPosts.count, 0, "Unmoved events post no notification")

        // Start moves: one change, one post.
        store.events = [stable, event("moving", start: 9000, end: 9600)]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), ["moving"], "Moved start surfaces as changed")
        try context.equal(changedPosts.count, 1, "Moved event posts the notification")
        try context.equal(changedPosts.last?.map(\.id), ["moving"], "Notification carries the moved event")

        // Window reverts to the original: still a change against the last
        // observation, so the event stays in the set and posts again.
        store.events = [stable, moving]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), ["moving"], "Reverted window counts as another change")
        try context.equal(changedPosts.count, 2, "Reverted window posts again")

        // Event vanishes from the fetch: pruned from memory, no post.
        store.events = [stable]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Removed event clears the changed set")
        try context.equal(changedPosts.count, 2, "Missing event posts nothing")

        // Reappears with its old window: no memory left, first-seen again.
        store.events = [stable, moving]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Reappearing event is fresh, not changed")
        try context.equal(changedPosts.count, 2, "Reappearing event posts nothing")
        // The reappearance re-entered the recent region; clear it again so
        // the next move flags against the raw rules.
        manager.markAllRecentAsRead()

        // Feature off: the disabled refresh clears the published set.
        store.events = [stable, event("moving", start: 9000, end: 9600)]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), ["moving"], "Change observed before the feature goes off")
        try context.equal(changedPosts.count, 3, "Change before the feature goes off posts once")
        defaults.set(false, forKey: Constants.Defaults.featureCalendar)
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Disabled feature clears the changed set")
        try context.equal(changedPosts.count, 3, "Disabled feature posts nothing")

        // The preference-toggle path wipes deep memory, but only when the
        // debounced observer sees the false state, so the post must land
        // while the feature is still off. After the wipe, the moved window
        // counts as first-seen: the re-enable fetch posts nothing.
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        // The observer debounces at 200 ms, so give it time to observe the
        // false state before flipping the preference back on: a coalesced
        // run would only see the final true state and never wipe memory.
        try await Task.sleep(nanoseconds: 400_000_000)
        store.events = [stable, event("moving", start: 10800, end: 11400)]
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        try await wait(context, "Re-enable fetch repopulates events") {
            manager.events.contains(where: { $0.id == "moving" })
        }
        // The wipe erased the old window, so the moved event is first-seen
        // again: no change, no post. Without the wipe the 10800 window
        // would differ from the pre-disable 9000 memory and post again.
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Wiped memory treats the moved event as first-seen")
        try context.equal(changedPosts.count, 3, "No post after the memory wipe")
        // A stable repeat of the same window stays quiet.
        await manager.refreshEvents()
        try context.equal(changedPosts.count, 3, "Stable window after the wipe posts nothing")
    }

    /// Past-aware change detection: a shift on an already-ended occurrence
    /// never flags, a recurring series keeps its occurrences apart, and an
    /// acknowledged change stays quiet until the times move again.
    private static func timeChangePastAndRecurrence(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("meeting-time-changes-past")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(try JSONEncoder().encode([calendar.id]), forKey: Constants.Defaults.selectedCalendars)
        let notifications = NotificationCenter()
        let store = CoverageEventStore()
        store.calendars = [calendar]
        let manager = MeetingManager(eventStore: store, nowProvider: { instant }, defaults: defaults, notificationCenter: notifications)
        await Task.yield()

        var changedPosts: [[CalendarEvent]] = []
        let changedObserver = notifications.publisher(for: .businessBarEventTimesChanged).sink { note in
            if let events = note.userInfo?["events"] as? [CalendarEvent] { changedPosts.append(events) }
        }
        defer { changedObserver.cancel() }

        // One-off event, entirely in the past: seen at its original window,
        // then the window shifts. A moved past meeting asks nothing of the
        // user, so no flag, no post.
        store.events = [event("past-once", start: -7200, end: -6600)]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Past event first-seen without a change")
        store.events = [event("past-once", start: -9000, end: -8400)]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Shifted past event never flags")
        try context.equal(changedPosts.count, 0, "Shifted past event posts nothing")

        // Recurring series, two occurrences sharing the id: one past, one
        // inside the agenda window so next-event eligibility is observable.
        let pastOccurrenceDate = instant.addingTimeInterval(-48 * 3600)
        let futureOccurrenceDate = instant.addingTimeInterval(24 * 3600)
        let pastOccurrence = event("series", start: -48 * 3600 - 600, end: -48 * 3600, occurrence: pastOccurrenceDate, recurring: true)
        let futureOccurrence = event("series", start: 24 * 3600, end: 24 * 3600 + 600, occurrence: futureOccurrenceDate, recurring: true)
        store.events = [pastOccurrence, futureOccurrence]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Series occurrences first-seen without a change")
        try context.equal(manager.nextEvent?.id, "series", "Future occurrence is the next event")
        // Both occurrences just entered the recent region; clear it so the
        // move below exercises the raw change rules.
        manager.markAllRecentAsRead()

        // Both occurrences move at once: only the future one flags.
        let movedPastOccurrence = event("series", start: -50 * 3600 - 600, end: -50 * 3600, occurrence: pastOccurrenceDate, recurring: true)
        let movedFutureOccurrence = event("series", start: 26 * 3600, end: 26 * 3600 + 600, occurrence: futureOccurrenceDate, recurring: true)
        store.events = [movedPastOccurrence, movedFutureOccurrence]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), ["series"], "Only the future occurrence flags, the past one stays silent")
        try context.equal(changedPosts.count, 1, "Future occurrence move posts once")
        try context.equal(changedPosts.last?.map(\.id), ["series"], "Post carries only the future occurrence")

        // Acknowledging the flag quiets it; the held window stays quiet on
        // refresh, and a further shift flags again because it is new news.
        manager.markTimeChangedAsRead(manager.timeChangedEvents[0])
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Acknowledged flag leaves the section")
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Held window does not re-flag an acknowledged change")
        try context.equal(changedPosts.count, 1, "Held window posts nothing")
        store.events = [movedPastOccurrence, event("series", start: 27 * 3600, end: 27 * 3600 + 600, occurrence: futureOccurrenceDate, recurring: true)]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), ["series"], "A further shift re-flags an acknowledged occurrence")
        try context.equal(changedPosts.count, 2, "Further shift posts again")

        // Second event joins: first-seen fetch flags nothing, its own move
        // flags it beside the series, then Acknowledge all clears both.
        let otherEvent = event("other", start: 30 * 3600, end: 30 * 3600 + 600)
        store.events = [movedPastOccurrence, event("series", start: 27 * 3600, end: 27 * 3600 + 600, occurrence: futureOccurrenceDate, recurring: true), otherEvent]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "First-seen event and stable series flag nothing")
        // The new event entered the recent region; clear it before the move.
        manager.markAllRecentAsRead()
        store.events = [movedPastOccurrence, event("series", start: 28 * 3600, end: 28 * 3600 + 600, occurrence: futureOccurrenceDate, recurring: true), event("other", start: 31 * 3600, end: 31 * 3600 + 600)]
        await manager.refreshEvents()
        try context.equal(Set(manager.timeChangedEvents.map(\.id)), Set(["series", "other"]), "Both moved rows flag together")
        manager.markAllTimeChangedAsRead()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Acknowledge all empties the section")
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Held windows stay acknowledged after refresh")

        // Dismiss all: section empties and both events hide everywhere.
        store.events = [movedPastOccurrence, event("series", start: 29 * 3600, end: 29 * 3600 + 600, occurrence: futureOccurrenceDate, recurring: true), event("other", start: 32 * 3600, end: 32 * 3600 + 600)]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.count, 2, "Both rows flag again after further shifts")
        manager.dismissAllTimeChanged()
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Dismiss all empties the section")
        try context.equal(manager.nextEvent, nil, "Dismissed rows lose next-event eligibility")
        await manager.refreshEvents()
        try context.equal(manager.events.filter { $0.id == "series" || $0.id == "other" }.map(\.id), [], "Dismiss all hides the events from the agenda too")
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Dismissed rows cannot re-flag on refresh")
    }

    /// Bulk actions on the recently-added region: mark-all keeps the agenda
    /// untouched, dismiss-all hides the events everywhere.
    private static func recentBulkActions(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("meeting-recent-bulk")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(try JSONEncoder().encode([calendar.id]), forKey: Constants.Defaults.selectedCalendars)
        let notifications = NotificationCenter()
        let store = CoverageEventStore()
        store.calendars = [calendar]
        let manager = MeetingManager(eventStore: store, nowProvider: { instant }, defaults: defaults, notificationCenter: notifications)
        await Task.yield()

        let first = event("recent-1", start: 3600, end: 4200)
        let second = event("recent-2", start: 7200, end: 7800)
        store.events = [first, second]
        await manager.refreshEvents()
        try context.equal(Set(manager.recentEvents.map(\.id)), Set(["recent-1", "recent-2"]), "Both events feed the recent region")

        manager.markAllRecentAsRead()
        try context.equal(manager.recentEvents.map(\.id), [], "Mark all as read empties the recent region")
        try context.equal(manager.events.map(\.id).count, 2, "Read rows keep their agenda places")
        try context.equal(manager.nextEvent?.id, "recent-1", "Read rows keep next-event eligibility")
        await manager.refreshEvents()
        try context.equal(manager.recentEvents.map(\.id), [], "Refresh cannot re-announce rows marked read in bulk")

        store.events = []
        await manager.refreshEvents()
        store.events = [first, second]
        await manager.refreshEvents()
        try context.equal(Set(manager.recentEvents.map(\.id)), Set(["recent-1", "recent-2"]), "Rows come back once their events left the fetch window")

        manager.dismissAllRecentEvents()
        try context.equal(manager.recentEvents.map(\.id), [], "Dismiss all empties the recent region")
        try context.equal(manager.nextEvent, nil, "Dismissed rows lose next-event eligibility")
        await manager.refreshEvents()
        try context.equal(manager.events.map(\.id), [], "Dismiss all hides the events from the agenda")
        try context.equal(manager.recentEvents.map(\.id), [], "Dismissed rows cannot come back on refresh")
    }

    /// Overlap between the Recently added and Changed times regions: while
    /// an event still sits in the recent region, its time moves must not
    /// flag as changes. Once it leaves the region (marked read here, or the
    /// window passing), a later move flags again. A move suppressed while
    /// in the region is consumed: the window bookkeeping keeps updating, so
    /// it is never replayed after the event leaves the region without a
    /// further move.
    private static func recentAndTimeChangeOverlap(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("meeting-recent-change-overlap")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(try JSONEncoder().encode([calendar.id]), forKey: Constants.Defaults.selectedCalendars)
        let notifications = NotificationCenter()
        let store = CoverageEventStore()
        store.calendars = [calendar]
        var now = instant
        let manager = MeetingManager(eventStore: store, nowProvider: { now }, defaults: defaults, notificationCenter: notifications)
        await Task.yield()

        var changedPosts: [[CalendarEvent]] = []
        let changedObserver = notifications.publisher(for: .businessBarEventTimesChanged).sink { note in
            if let events = note.userInfo?["events"] as? [CalendarEvent] { changedPosts.append(events) }
        }
        defer { changedObserver.cancel() }

        // First fetch seeds both regions: the event is recent, no change
        // baseline exists yet. The event sits 30 h out so the whole sequence
        // below stays inside the 7-day fetch window while `now` advances
        // past the 24 h recent window.
        store.events = [event("overlap", start: 30 * 3600, end: 30 * 3600 + 600)]
        await manager.refreshEvents()
        try context.equal(manager.recentEvents.map(\.id), ["overlap"], "Overlap event feeds the recent region")
        try context.equal(manager.timeChangedEvents.map(\.id), [], "First fetch seeds no change baseline")
        try context.equal(changedPosts.count, 0, "First fetch posts no time-change notification")

        // Time moves while the event is still recent: the flag and the
        // notification are suppressed, the row stays only in the recent
        // region, no duplicate row appears.
        store.events = [event("overlap", start: 30 * 3600 + 1200, end: 30 * 3600 + 1800)]
        await manager.refreshEvents()
        try context.equal(manager.recentEvents.map(\.id), ["overlap"], "Event still recent after its suppressed move")
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Move while recent does not flag as changed")
        try context.equal(changedPosts.count, 0, "Suppressed move posts no notification")

        // The suppressed change is consumed: marking the row read and
        // refreshing with the held times does not replay it, the window
        // memory already holds the current times.
        manager.markRecentAsRead("overlap")
        await manager.refreshEvents()
        try context.equal(manager.recentEvents.map(\.id), [], "Read row stays out of the recent region")
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Held window does not replay the suppressed change")
        try context.equal(changedPosts.count, 0, "No replay post for the suppressed change")

        // The recent window passes without a further move: the event keeps
        // its absolute times and stays inside the fetch window, the memory
        // already holds them, so nothing replays.
        now = instant.addingTimeInterval(25 * 3600)
        await manager.refreshEvents()
        try context.equal(manager.recentEvents.map(\.id), [], "Recent window expired for the read row")
        try context.equal(manager.timeChangedEvents.map(\.id), [], "Expired recent window does not replay the suppressed change")
        try context.equal(changedPosts.count, 0, "No replay post after the window expires")

        // Regression guard: an event outside the recent region flags a time
        // move exactly as before the suppression rule existed.
        store.events = [event("overlap", start: 30 * 3600 + 2400, end: 30 * 3600 + 3000)]
        await manager.refreshEvents()
        try context.equal(manager.timeChangedEvents.map(\.id), ["overlap"], "Non-recent event flags its move as before")
        try context.equal(changedPosts.count, 1, "Non-recent move posts as before")
    }

    private static func ekParticipantMapping(_ context: CoverageContext) throws {
        let store = EKEventStore()
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = "Mapping"
        ekEvent.startDate = instant
        ekEvent.endDate = instant.addingTimeInterval(600)
        try context.equal(CalendarEvent(from: ekEvent, calendar: calendar).myRSVPStatus, .accepted, "Event without attendees reads as accepted")
        // Direct status mapping: EKParticipant instances cannot be built
        // outside a real event store, so the switch is exercised by status.
        try context.equal(CalendarEvent.rsvpStatus(of: .pending), .pending, "Pending participant maps to pending")
        try context.equal(CalendarEvent.rsvpStatus(of: .accepted), .accepted, "Accepted participant maps to accepted")
        try context.equal(CalendarEvent.rsvpStatus(of: .declined), .declined, "Declined participant maps to declined")
        try context.equal(CalendarEvent.rsvpStatus(of: .tentative), .tentative, "Tentative participant maps to tentative")
        try context.equal(CalendarEvent.rsvpStatus(of: .unknown), .unknown, "Unknown participant maps to unknown")
        try context.equal(CalendarEvent.rsvpStatus(of: .delegated), .unknown, "Delegated participant maps to unknown")
        try context.equal(CalendarEvent.rsvpStatus(of: .completed), .unknown, "Completed participant maps to unknown")
    }

    /// RSVP replies through the EventKit adapter: the private participation
    /// status setter stays guarded, and every reject path returns false.
    private static func ekRespond(_ context: CoverageContext) async throws {
        let backend = CoverageCalendarBackend()
        let adapter = EKEventStoreAdapter(backend: backend)
        let ekStore = EKEventStore()
        let ekEvent = EKEvent(eventStore: ekStore)
        ekEvent.title = "Local invite"
        ekEvent.startDate = instant
        ekEvent.endDate = instant.addingTimeInterval(600)
        backend.storedEvents["ek-invite"] = ekEvent
        let identifier = ekEvent.eventIdentifier ?? "ek-invite"
        backend.storedEvents[identifier] = ekEvent

        var answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .accepted)
        try context.expect(!answered && backend.saveCalls.isEmpty, "Denied access rejects the answer")

        backend.hasAccess = true
        answered = await adapter.respond(toEventID: "missing", calendarID: "work", status: .accepted)
        try context.expect(!answered && backend.saveCalls.isEmpty, "Missing event rejects the answer")

        answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .pending)
        try context.expect(!answered && backend.saveCalls.isEmpty, "Pending status is not written back")
        answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .unknown)
        try context.expect(!answered && backend.saveCalls.isEmpty, "Unknown status is not written back")

        answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .accepted)
        try context.expect(answered && backend.saveCalls.count == 1, "Accepted answer saves the event")

        answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .declined)
        try context.expect(answered && backend.saveCalls.count == 2, "Declined answer saves the event")

        answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .tentative)
        try context.expect(answered && backend.saveCalls.count == 3, "Tentative answer saves the event")

        backend.saveResults[""] = false
        answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .accepted)
        try context.expect(!answered && backend.saveCalls.count == 4, "Save failure returns false after the attempt")

        backend.saveError = CoverageCalendarBackend.Failure.unavailable
        answered = await adapter.respond(toEventID: "ek-invite", calendarID: "work", status: .accepted)
        try context.expect(!answered && backend.saveCalls.count == 5, "Throwing save lands in the catch and reports failure")
        backend.saveError = nil

        // Native backend through the coverage seam: real store, injected
        // access flag. The unfiled event makes save throw, so no state is touched.
        // The store answers its own access request (PromptFreeEventStore) so
        // headless hosts cannot hang on a TCC prompt nobody can answer.
        // The provider hands back the same instance, because a successful
        // access request refreshes sources and the error probe below must
        // reach the store the backend actually holds.
        let promptFree = PromptFreeEventStore()
        let nativeBackend = EKEventStoreAdapter.nativeBackendForCoverage(store: promptFree, hasAccess: true) { promptFree }
        let nativeAdapter = EKEventStoreAdapter(backend: nativeBackend)
        answered = await nativeAdapter.respond(toEventID: "native-missing", calendarID: "work", status: .accepted)
        try context.expect(!answered, "Native lookup miss rejects the answer")
        let unfiled = EKEvent(eventStore: EKEventStore())
        unfiled.title = "Unfiled"
        unfiled.startDate = instant
        unfiled.endDate = instant.addingTimeInterval(600)
        do {
            _ = try nativeBackend.save(unfiled)
            try context.expect(false, "Unfiled event save should not succeed")
        } catch {
            try context.expect(true, "Native save surfaces EventKit errors to the caller")
        }
        try await nativeBackendSurface(context, nativeBackend, nativeAdapter, promptFree: promptFree)
    }

    /// NativeCalendarStoreBackend against the real EventKit store: the read
    /// surface (refresh/calendars/events/query) executes against live EventKit,
    /// and the request continuation resumes with the OS answer instead of
    /// throwing. Store contents depend on the host calendar state, so checks
    /// mirror counts rather than assume emptiness.
    private static func nativeBackendSurface(_ context: CoverageContext, _ backend: CalendarStoreBackend, _ adapter: EKEventStoreAdapter, promptFree: PromptFreeEventStore) async throws {
        backend.refreshSources()
        let nativeCalendars = backend.calendars()
        _ = backend.events(from: instant.addingTimeInterval(-3600), to: instant.addingTimeInterval(3600), calendars: nativeCalendars)

        let mappedCalendars = try await adapter.fetchCalendars()
        try context.equal(mappedCalendars.count, nativeCalendars.count, "Adapter fetchCalendars mirrors the native store list")
        let emptyEvents = try await adapter.fetchEvents(from: instant.addingTimeInterval(-3600), to: instant.addingTimeInterval(3600), calendars: [])
        try context.expect(emptyEvents.isEmpty, "Adapter fetchEvents filters to no calendars against the native store")

        // Reaching this point proves the requestAccess continuation resumed
        // with the OS answer instead of throwing; the granted value itself is
        // host TCC state and is not asserted.
        _ = try await adapter.requestAccess()

        // The access request can also fail, and the failure must resume the
        // same continuation through the throw path.
        promptFree.accessAnswer = (false, CocoaError(.userActivityConnectionUnavailable))
        do {
            _ = try await adapter.requestAccess()
            try context.expect(false, "Native access error should surface as a throw")
        } catch {
            try context.expect(true, "Native access error surfaces through the continuation")
        }
    }

    private static func wait(_ context: CoverageContext, _ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try context.expect(condition(), message)
    }
}
