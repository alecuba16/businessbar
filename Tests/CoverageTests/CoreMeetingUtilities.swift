import AppKit
import EventKit
import Foundation
@testable import BusinessBarCore

@MainActor
private final class CoverageEventStore: EventStoreProtocol {
    enum Failure: Error { case unavailable }
    var permission = true
    var fail = false
    var calendars: [MBCalendar] = []
    var events: [CalendarEvent] = []
    var requests: [(Date, Date, [String])] = []
    var duringFetch: (() async -> Void)?

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
}

@MainActor
private final class CoverageCalendarBackend: CalendarStoreBackend {
    enum Failure: Error { case unavailable }
    var hasAccess = false
    var grant = true
    var fail = false
    var refreshes = 0
    var calendarReads = 0
    func requestAccess() async throws -> Bool {
        if fail { throw Failure.unavailable }
        return grant
    }
    func refreshSources() { refreshes += 1 }
    func calendars() -> [EKCalendar] { calendarReads += 1; return [] }
    func events(from startDate: Date, to endDate: Date, calendars: [EKCalendar]) -> [EKEvent] { [] }
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
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private static let instant = Date(timeIntervalSince1970: 1_772_964_000)
    private static let calendar = MBCalendar(id: "work", title: "Work", color: "#123456", source: "Fixture")

    private static func event(_ id: String, start: TimeInterval = -60, end: TimeInterval = 600, status: CalendarEvent.EventStatus = .confirmed) -> CalendarEvent {
        CalendarEvent(id: id, title: id, startDate: instant.addingTimeInterval(start), endDate: instant.addingTimeInterval(end), location: nil, notes: nil, url: nil, calendar: calendar, organizer: "Organizer", attendees: ["Attendee"], status: status)
    }

    private static func plannerAndModels(_ context: CoverageContext) throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z")!
        let today = EventDisplayPlanner.fetchWindow(now: spring, includeTomorrow: false, calendar: gregorian)
        let tomorrow = EventDisplayPlanner.fetchWindow(now: spring, includeTomorrow: true, calendar: gregorian)
        try context.equal(today.end.timeIntervalSince(today.start), 23 * 3600, "DST fetch window uses calendar day")
        try context.equal(tomorrow.end.timeIntervalSince(today.end), 24 * 3600, "Tomorrow adds one calendar day")
        let ended = event("ended", end: 0)
        let live = event("live")
        let declined = event("declined", status: .canceled)
        try context.equal(EventDisplayPlanner.nextEvent(from: [ended, live], now: instant)?.id, "live", "End boundary is excluded")
        try context.expect(EventDisplayPlanner.nextEvent(from: [live], dismissedIDs: ["live"], now: instant) == nil, "Dismissal wins over ongoing event")
        try context.equal(EventDisplayPlanner.filter([live, declined], dismissedIDs: [], showDeclined: false).map(\.id), ["live"], "Declined events hidden")
        try context.equal(EventDisplayPlanner.filter([live, declined], dismissedIDs: ["live"], showDeclined: true).map(\.id), ["declined"], "Visibility does not restore dismissed event")
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

    private static func wait(_ context: CoverageContext, _ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try context.expect(condition(), message)
    }
}
