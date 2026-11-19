import AppKit
import BusinessBarCore
import Combine
import Foundation
import UserNotifications
@testable import BusinessBar

/// RSVP surface scenarios: status-bar pending badge, invitations menu
/// section, the iterate panel, and the AppDelegate routing that wires
/// notification answers back into the meeting manager.
@MainActor
enum AppRSVPScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        await run("rsvp badge", failures: &failures) { try await statusBadge(context) }
        await run("time badge", failures: &failures) { try await timeChangeBadge(context) }
        await run("rsvp panel", failures: &failures) { try await panel(context) }
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private static func run(_ name: String, failures: inout [String], body: @escaping () async throws -> Void) async {
        print("RUN: app rsvp \(name)")
        do {
            try await body()
            print("PASS: app rsvp \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL: app rsvp \(name): \(error)")
        }
    }

    private static func settle() async {
        for _ in 0..<8 { await Task.yield() }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Pending-event store recording every RSVP reply.
    private final class Store: EventStoreProtocol {
        var events: [CalendarEvent] = []
        var receivedRSVPs: [(String, String, CalendarEvent.RSVPStatus)] = []
        var respondResult = true
        func requestAccess() async throws -> Bool { true }
        func fetchCalendars() async throws -> [MBCalendar] { [] }
        func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] { events }
        func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
            receivedRSVPs.append((eventID, calendarID, status))
            return respondResult
        }
    }

    /// Status item backing capturing button state.
    private final class Backing: StatusItemBacking {
        let ownedButton = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        var button: NSButton? { ownedButton }
        var menu: NSMenu?
        var length: CGFloat
        init(_ length: CGFloat) { self.length = length }
    }

    private final class Monitor: BadgeMonitoring {
        var onBadgeUpdate: ((String, Int) -> Void)?
        func startMonitoring(apps: [MonitoredApp]) {}
        func stopMonitoring() {}
        func updateAppElements(for apps: [MonitoredApp]) {}
        func restartPollTimer() {}
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func invite(_ id: String, in calendar: MBCalendar) -> CalendarEvent {
        invite(id, in: calendar, startingIn: 600)
    }

    /// Offsets pick the invite's slot relative to `now`: positive offsets
    /// build upcoming invites, negative offsets already-ended ones. The
    /// pending filter drops ended invites (endDate > now), so only
    /// upcoming ones drive the badge.
    private static func invite(_ id: String, in calendar: MBCalendar, startingIn offset: TimeInterval) -> CalendarEvent {
        CalendarEvent(
            id: id, title: "Invite \(id)",
            startDate: now.addingTimeInterval(offset), endDate: now.addingTimeInterval(offset + 600),
            location: "Fixture room", notes: nil, url: nil, calendar: calendar,
            organizer: "Owner", attendees: ["Owner", "Me"], myRSVPStatus: .pending
        )
    }

    /// Status bar: "N?" suffix while a meeting is shown, calendar badge
    /// icon while idle, and the answer-invites effect delegation.
    private static func statusBadge(_ c: CoverageContext) async throws {
        let defaults = try c.defaults("rsvp-status")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(true, forKey: Constants.Defaults.featureBadges)
        defaults.set(false, forKey: Constants.Defaults.featureNoSleep)
        defaults.set(0, forKey: Constants.Defaults.meetingTitleMaxLength)
        defaults.set(0, forKey: Constants.Defaults.timeRoundingThreshold)
        defaults.set("relative", forKey: Constants.Defaults.timeFormat)
        let calendar = MBCalendar(id: "rsvp-cal", title: "RSVP", color: "#112233", source: "Fixture")
        defaults.set(try JSONEncoder().encode([calendar.id]), forKey: Constants.Defaults.selectedCalendars)
        let notifications = NotificationCenter()
        let store = Store()
        // Ended invites no longer count as pending, so the badge needs
        // upcoming ones; their meeting rows must be dismissed below to
        // reach the idle-with-invites state.
        store.events = [invite("badge-one", in: calendar, startingIn: 1200), invite("badge-two", in: calendar, startingIn: 1800)]
        let meetings = MeetingManager(eventStore: store, nowProvider: { now }, defaults: defaults, notificationCenter: notifications)
        let unscheduled: (TimeInterval, @escaping () -> Void) -> Timer = { interval, action in
            Timer(timeInterval: interval, repeats: true) { _ in action() }
        }
        let badges = BadgeManager(defaults: defaults, notifications: notifications, trust: { false }, monitor: Monitor(), schedule: unscheduled, requestPermission: {}, openSettings: { _ in })
        let noSleep = NoSleepManager(defaults: defaults, notifications: notifications, workspace: NotificationCenter(), trust: { false }, now: { now }, schedule: unscheduled, activateSleep: { _ in }, deactivateSleep: {}, startActivity: {}, stopActivity: {})
        var items: [Backing] = []
        var answerOpens = 0
        var effects = StatusBarController.Effects()
        effects.makeStatusItem = { length in let backing = Backing(length); items.append(backing); return backing }
        effects.scheduleTimer = { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } }
        effects.now = { now }
        effects.answerInvites = { answerOpens += 1 }
        // The controller must stay alive: its Combine cancellables die with
        // deallocation and the button would freeze at the init-time layout.
        let controller = StatusBarController(meetingManager: meetings, badgeManager: badges, noSleepManager: noSleep, defaults: defaults, notifications: notifications, effects: effects, onShowPreferences: {})
        await settle()
        await meetings.refreshEvents()
        await settle()
        let button = items[0].ownedButton

        // Upcoming invites are live meetings, so the bar shows the
        // next-event text, not the badge.
        try c.expect(button.imagePosition == .noImage, "Upcoming pending invites surface as the next meeting")

        // Dismissing their rows leaves the invites pending: the idle
        // badge takes over.
        meetings.dismissEvent("badge-one")
        meetings.dismissEvent("badge-two")
        await settle()
        try c.expect(button.imagePosition == .imageOnly, "Dismissed rows with pending invites show the icon layout")
        try c.expect(button.image?.tiffRepresentation != nil, "Pending icon renders")

        // Ended pending invite stays out of the count while an upcoming one stays in.
        store.events = [invite("past", in: calendar, startingIn: -1200), invite("soon", in: calendar, startingIn: 1200)]
        await meetings.refreshEvents()
        await settle()
        let titleWithEnded = button.attributedTitle.string
        try c.expect(titleWithEnded.contains("1?") && !titleWithEnded.contains("2?"), "Ended pending invite does not add to the pending count")

        // Current meeting plus invites: text plus "2?" suffix.
        let current = CalendarEvent(
            id: "current", title: "Current meeting",
            startDate: now.addingTimeInterval(-300), endDate: now.addingTimeInterval(900),
            location: nil, notes: nil, url: nil, calendar: calendar,
            organizer: nil, attendees: [], myRSVPStatus: .accepted
        )
        store.events = [current, invite("one", in: calendar), invite("two", in: calendar)]
        await meetings.refreshEvents()
        await settle()
        try c.expect(button.imagePosition == .noImage, "Meeting shown removes the icon")
        let title = button.attributedTitle.string
        try c.expect(title.contains("2?"), "Meeting title carries the pending count suffix")

        // One invite answered: suffix shrinks to "1?".
        store.events = [current, invite("two", in: calendar)]
        await meetings.refreshEvents()
        await settle()
        try c.expect(button.attributedTitle.string.contains("1?"), "Answered invite drops the suffix count")

        // Answered: suffix disappears once nothing is pending.
        store.events = [current]
        await meetings.refreshEvents()
        await settle()
        try c.expect(!button.attributedTitle.string.contains("?"), "No pending invites means no suffix")

        // Menu rows still route through the effects closure: the payload
        // dispatch lives on MenuActionHandler, so fire the selector the same
        // way AppKit does on a click.
        store.events = [current, invite("one", in: calendar), invite("two", in: calendar)]
        await meetings.refreshEvents()
        await settle()
        if let menu = controller.mainMenuForCoverage {
            let inviteRows = menu.items.filter { row in
                (row.representedObject as? MenuAction) != nil && row.action == #selector(MenuActionHandler.answerInvites)
            }
            try c.expect(inviteRows.count == 2, "Pending invitations rows appear in the menu")
            inviteRows.forEach { $0.target?.perform($0.action!, with: $0) }
            try c.expect(answerOpens == 2, "Invitation rows trigger the answer effect")
        } else {
            try c.expect(false, "Main menu should exist for coverage")
        }
    }

    /// Status bar for time changes: "N!" suffix while a meeting is shown,
    /// orange calendar badge while idle, and the Changed times menu rows
    /// route through the shared join/dismiss actions. The manager only flags
    /// a change between two fetches, so each store mutation below is
    /// followed by a refresh to build the before/after pair.
    private static func timeChangeBadge(_ c: CoverageContext) async throws {
        let defaults = try c.defaults("rsvp-time-badge")
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(true, forKey: Constants.Defaults.featureBadges)
        defaults.set(false, forKey: Constants.Defaults.featureNoSleep)
        defaults.set(0, forKey: Constants.Defaults.meetingTitleMaxLength)
        defaults.set(0, forKey: Constants.Defaults.timeRoundingThreshold)
        defaults.set("relative", forKey: Constants.Defaults.timeFormat)
        let calendar = MBCalendar(id: "time-cal", title: "Times", color: "#112233", source: "Fixture")
        defaults.set(try JSONEncoder().encode([calendar.id]), forKey: Constants.Defaults.selectedCalendars)
        let notifications = NotificationCenter()
        let store = Store()
        let moving = CalendarEvent(
            id: "moving", title: "Moved meeting",
            startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(4200),
            location: nil, notes: nil, url: URL(string: "https://zoom.us/j/123456789"), calendar: calendar,
            organizer: nil, attendees: [], myRSVPStatus: .accepted
        )
        store.events = [moving]
        let meetings = MeetingManager(eventStore: store, nowProvider: { now }, defaults: defaults, notificationCenter: notifications)
        let unscheduled: (TimeInterval, @escaping () -> Void) -> Timer = { interval, action in
            Timer(timeInterval: interval, repeats: false) { _ in action() }
        }
        let badges = BadgeManager(defaults: defaults, notifications: notifications, trust: { false }, monitor: Monitor(), schedule: unscheduled, requestPermission: {}, openSettings: { _ in })
        let noSleep = NoSleepManager(defaults: defaults, notifications: notifications, workspace: NotificationCenter(), trust: { false }, now: { now }, schedule: unscheduled, activateSleep: { _ in }, deactivateSleep: {}, startActivity: {}, stopActivity: {})
        var items: [Backing] = []
        var answerOpens = 0
        var effects = StatusBarController.Effects()
        effects.makeStatusItem = { length in let backing = Backing(length); items.append(backing); return backing }
        effects.scheduleTimer = { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } }
        effects.now = { now }
        effects.answerInvites = { answerOpens += 1 }
        let controller = StatusBarController(meetingManager: meetings, badgeManager: badges, noSleepManager: noSleep, defaults: defaults, notifications: notifications, effects: effects, onShowPreferences: {})
        await settle()
        await meetings.refreshEvents()
        await settle()
        let button = items[0].ownedButton

        // Baseline fetch: the event is first-seen, nothing changed yet.
        try c.expect(button.attributedTitle.string.contains("!") == false, "No change yet means no bang suffix")

        // Window moves: the live meeting text carries the orange "1!".
        let shifted = CalendarEvent(
            id: moving.id, title: moving.title,
            startDate: now.addingTimeInterval(5400), endDate: now.addingTimeInterval(6000),
            location: moving.location, notes: moving.notes, url: moving.meetingLink, calendar: calendar,
            organizer: moving.organizer, attendees: moving.attendees, myRSVPStatus: .accepted
        )
        store.events = [shifted]
        await meetings.refreshEvents()
        await settle()
        try c.expect(button.imagePosition == .noImage, "Moved meeting still shows as text")
        try c.expect(button.attributedTitle.string.contains("1!"), "Moved event adds the bang suffix")

        // Two changed events while a meeting shows: "2!" suffix.
        let second = CalendarEvent(
            id: "second", title: "Second meeting",
            startDate: now.addingTimeInterval(7200), endDate: now.addingTimeInterval(7800),
            location: nil, notes: nil, url: nil, calendar: calendar,
            organizer: nil, attendees: [], myRSVPStatus: .accepted
        )
        store.events = [shifted, second]
        await meetings.refreshEvents()
        await settle()
        try c.expect(!button.attributedTitle.string.contains("2!"), "First-seen second event is not counted as changed")

        // Both move in the same fetch: "2!" suffix appears.
        let secondShifted = CalendarEvent(
            id: second.id, title: second.title,
            startDate: now.addingTimeInterval(9000), endDate: now.addingTimeInterval(9600),
            location: second.location, notes: second.notes, url: second.meetingLink, calendar: calendar,
            organizer: second.organizer, attendees: second.attendees, myRSVPStatus: .accepted
        )
        let reshifted = CalendarEvent(
            id: shifted.id, title: shifted.title,
            startDate: now.addingTimeInterval(6600), endDate: now.addingTimeInterval(7200),
            location: shifted.location, notes: shifted.notes, url: shifted.meetingLink, calendar: calendar,
            organizer: shifted.organizer, attendees: shifted.attendees, myRSVPStatus: .accepted
        )
        store.events = [reshifted, secondShifted]
        await meetings.refreshEvents()
        await settle()
        try c.expect(button.attributedTitle.string.contains("2!"), "Two moved events carry the combined suffix")

        // Idle badge: shift both windows into the past so no next event
        // shows. The past windows differ from the last observation, so the
        // changed count survives and the icon branch renders.
        let pastMoving = CalendarEvent(
            id: shifted.id, title: shifted.title,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-6600),
            location: shifted.location, notes: shifted.notes, url: shifted.meetingLink, calendar: calendar,
            organizer: shifted.organizer, attendees: shifted.attendees, myRSVPStatus: .accepted
        )
        let pastSecond = CalendarEvent(
            id: secondShifted.id, title: secondShifted.title,
            startDate: now.addingTimeInterval(-5400), endDate: now.addingTimeInterval(-4800),
            location: secondShifted.location, notes: secondShifted.notes, url: secondShifted.meetingLink, calendar: calendar,
            organizer: secondShifted.organizer, attendees: secondShifted.attendees, myRSVPStatus: .accepted
        )
        store.events = [pastMoving, pastSecond]
        await meetings.refreshEvents()
        await settle()
        try c.expect(button.imagePosition == .imageOnly, "Idle with changes shows the icon layout")
        try c.expect(button.image?.tiffRepresentation != nil, "Changed-times icon renders")
        // Missing-symbol fallback: SF Symbols ship with the OS so the
        // production name always resolves; the coverage hook drives the
        // branch with a nonexistent name and must fall back to the app icon.
        let fallbackIcon = controller.timeChangedIconFallbackForCoverage()
        try c.expect(fallbackIcon === controller.cachedAppIconForCoverage, "Missing symbol falls back to the branded icon")

        // The controller keeps a persistent menu on the backing; when the
        // fixture backing has none yet, hand it one so menuWillOpen can
        // populate it the same way AppKit does on a real click.
        if items[0].menu == nil { items[0].menu = NSMenu() }
        guard let menu = items[0].menu else { throw CoverageContext.Failure(description: "Status backing has no menu") }
        controller.menuWillOpen(menu)
        try c.expect(menu.item(withTitle: "Changed times") != nil, "Changed times header appears in the menu")
        try c.expect(menu.items.contains(where: { $0.title.hasPrefix("Moved meeting ·") }), "Changed row lists the moved event")

        // Windows move back to upcoming: every seen event differs again,
        // and neither was dismissed, so the text layout resumes with a
        // "2!" suffix before the final stable fetch clears it.
        store.events = [reshifted, secondShifted]
        await meetings.refreshEvents()
        await settle()
        try c.expect(button.attributedTitle.string.contains("2!"), "Moved-back windows count as changed again")

        // Everything back to a stable window: suffix disappears.
        store.events = [reshifted, secondShifted]
        await meetings.refreshEvents()
        await settle()
        try c.expect(!button.attributedTitle.string.contains("!"), "Stable windows clear the suffix")
    }

    /// Iterate panel: present with two invites, answer both, verify the
    /// responder received both replies and the panel closed itself.
    private static func panel(_ c: CoverageContext) async throws {
        let store = Store()
        let calendar = MBCalendar(id: "rsvp-cal", title: "RSVP", color: "#112233", source: "Fixture")
        let first = invite("first", in: calendar)
        let second = invite("second", in: calendar)
        var pending = [first, second]
        var responses: [(String, CalendarEvent.RSVPStatus)] = []
        var presentedPanels = 0
        let controller = RSVPPanelController(effects: .init(
            makePanel: {
                presentedPanels += 1
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 360, height: 10),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false
                )
                panel.isReleasedWhenClosed = false
                return panel
            },
            respond: { event, status in
                responses.append((event.id, status))
                return store.respondResult
            },
            pendingEvents: { pending }
        ))

        // Empty pending list never creates a panel.
        pending = []
        controller.present()
        try c.equal(presentedPanels, 0, "No pending invites means no panel")

        // Two invites: panel opens on the first.
        pending = [first, second]
        controller.present()
        try c.equal(presentedPanels, 1, "Panel created for pending invites")

        // Drive the store: answer advances; failure keeps the invite and
        // shows the error line; the last answer closes the panel.
        let panelStore = controller.storeForCoverage
        try c.equal(panelStore.progressText, "1 of 2", "Progress text starts at the first invite")
        panelStore.answer(.accepted)
        await settle()
        try c.equal(responses.count, 1, "First answer routes to the responder")
        try c.equal(responses.first?.0, "first", "Answer carries the current invite")
        try c.equal(responses.first?.1, .accepted, "Yes maps to accepted")
        try c.equal(panelStore.progressText, "2 of 2", "Answering advances to the next invite")

        store.respondResult = false
        panelStore.answer(.declined)
        await settle()
        try c.expect(panelStore.lastError != nil, "Failed answer surfaces the error message")
        try c.equal(panelStore.progressText, "2 of 2", "Failed answer stays on the same invite")

        store.respondResult = true
        panelStore.answer(.tentative)
        await settle()
        try c.equal(responses.map(\.1), [.accepted, .declined, .tentative], "Every button maps to its status")
        try c.expect(!panelIsVisible(controller), "Finishing the last invite closes the panel")

        // Reopen after close: the panel object is reused, so no new panel
        // is created until the controller itself goes away.
        controller.present()
        try c.equal(presentedPanels, 1, "Second presentation reuses the existing panel")
        try c.expect(panelIsVisible(controller), "Reopened panel is visible again")

        // The view's close button routes through onClose to dismissPanel.
        try c.expect(pressCloseButton(on: controller), "Close button press reaches the view action")
        try c.expect(!panelIsVisible(controller), "Close button hides the panel")
    }

    /// Presses the hosted panel's close button through the accessibility
    /// surface, exactly like a real click.
    private static func pressCloseButton(on controller: RSVPPanelController) -> Bool {
        guard let panel = controller.panelForCoverage, let content = panel.contentView else { return false }
        OwnedAccessibility.materialize()
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let elements = OwnedAccessibility.elements(in: content)
        guard let close = elements.first(where: {
            ($0.accessibilityLabel() ?? "").contains("Close") || ($0.accessibilityTitle() ?? "").contains("Close")
        }), close.isAccessibilityEnabled() else { return false }
        return close.accessibilityPerformPress()
    }

    private static func panelIsVisible(_ controller: RSVPPanelController) -> Bool {
        controller.panelForCoverage?.isVisible == true
    }
}