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

    /// Negative offsets build already-ended invites: pendingRSVPEvents keeps
    /// them (no time filter) while nextEvent drops them (endDate > now),
    /// which is exactly the idle-with-badge state.
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
        store.events = [invite("one", in: calendar, startingIn: -1200), invite("two", in: calendar, startingIn: -900)]
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

        // Idle with two pending invites: badge icon, no meeting text.
        try c.expect(button.imagePosition == .imageOnly, "Idle pending invites show the icon layout")
        try c.expect(button.image?.tiffRepresentation != nil, "Pending icon renders")

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