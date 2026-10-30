import AppKit
import Foundation
import KeyboardShortcuts
@testable import BusinessBar
@testable import BusinessBarCore

// Both modules expose `Constants`; production status behavior reads the app target's keys.
private typealias Constants = BusinessBar.Constants

@MainActor
enum AppStatusScenarios {
    static func run(_ context: CoverageContext) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(context)
        await settle()
        try await rendering(context, fixture)
        try await badges(context, fixture)
        try await shortcutsAndMenu(context, fixture)
    }

    private static func settle() async {
        for _ in 0..<8 { await Task.yield() }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func rendering(_ c: CoverageContext, _ f: Fixture) async throws {
        let button = f.items[0].ownedButton
        try c.equal(button.imagePosition, .imageOnly, "Idle layout is icon only")
        try c.expect(button.image != nil && button.image?.isTemplate == false, "Idle uses branded non-template icon")
        try c.expect(button.image?.tiffRepresentation != nil, "Idle branded image renders offscreen")
        let idleIcon = button.image
        try c.equal(button.attributedTitle.string, "", "Idle title starts empty")
        try c.equal(f.timerIntervals, [60], "Calendar schedules one minute refresh")

        for (minutes, threshold, expected) in [(5, 0, "5m"), (60, 0, "1h"), (91, 0, "1h31m"), (89, 1, "1h"), (90, 1, "2h"), (119, 2, "1h59m"), (120, 2, "2h"), (61, -1, "1h1m")] {
            f.defaults.set(threshold, forKey: Constants.Defaults.timeRoundingThreshold)
            f.store.events = [f.event(minutes: minutes)]
            await f.meetings.refreshEvents()
            await settle()
            try c.equal(button.imagePosition, .noImage, "Meeting-only layout removes icon")
            try c.expect(button.image == nil, "Meeting-only resets prior image")
            try c.equal(button.attributedTitle.string, "Status planning in \(expected)  ", "Relative threshold \(threshold), minutes \(minutes)")
        }
        f.store.events = [f.event(minutes: -10)]
        await f.meetings.refreshEvents()
        await settle()
        try c.equal(button.attributedTitle.string, "Status planning (ends 20m)  ", "Ongoing meeting formats remaining time")
        f.defaults.set("absolute", forKey: Constants.Defaults.timeFormat)
        f.preferencesChanged()
        await settle()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let event = f.store.events[0]
        let range = "(\(formatter.string(from: event.startDate))-\(formatter.string(from: event.endDate)))"
        try c.equal(button.attributedTitle.string, "Status planning \(range)  ", "Absolute times retain both boundaries")
        f.defaults.set(6, forKey: Constants.Defaults.meetingTitleMaxLength)
        f.preferencesChanged()
        await settle()
        try c.expect(!button.attributedTitle.string.contains("Status planning"), "Meeting title obeys configured truncation")
        f.defaults.set(0, forKey: Constants.Defaults.meetingTitleMaxLength)
        f.defaults.set("invalid", forKey: Constants.Defaults.timeFormat)

        f.noSleep.activate(duration: nil)
        await settle()
        try c.equal(button.imagePosition, .imageRight, "Meeting and NoSleep put cup to right")
        try c.expect(button.image != nil && !button.attributedTitle.string.isEmpty, "Combined state keeps icon and text")
        try c.expect(button.image?.tiffRepresentation != nil, "Infinite cup and badge render offscreen")
        let infiniteIcon = button.image
        f.store.events = []
        await f.meetings.refreshEvents()
        await settle()
        try c.equal(button.imagePosition, .imageOnly, "NoSleep alone is icon only")
        try c.equal(button.attributedTitle.string, "", "NoSleep alone clears meeting text")
        try c.expect(button.image === infiniteIcon, "Infinite NoSleep icon is cached")
        f.noSleep.activate(duration: 1800)
        f.preferencesChanged()
        await settle()
        try c.expect(button.image?.tiffRepresentation != nil, "Timed cup and clock render offscreen")
        let timedIcon = button.image
        try c.expect(timedIcon != nil && timedIcon !== infiniteIcon, "Timed NoSleep has separate icon")
        f.preferencesChanged()
        await settle()
        try c.expect(button.image === timedIcon, "Timed NoSleep icon is cached")
        f.defaults.set(false, forKey: Constants.Defaults.featureNoSleep)
        f.preferencesChanged()
        await settle()
        try c.expect(button.image === idleIcon, "Disabled NoSleep returns original idle icon")
        f.noSleep.deactivate()
        f.defaults.set(true, forKey: Constants.Defaults.featureNoSleep)
        f.defaults.set(false, forKey: Constants.Defaults.featureCalendar)
        f.preferencesChanged()
        await settle()
        try c.expect(f.timers.allSatisfy { !$0.isValid }, "Calendar gate invalidates minute timers")
        f.defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        f.preferencesChanged()
        await settle()
        try c.equal(f.timerIntervals.last, 60, "Calendar re-enable restarts minute timer")
        f.timers.last?.fire()
        await settle()
    }

    private static func badges(_ c: CoverageContext, _ f: Fixture) async throws {
        let iconURL = try c.temporaryDirectory("status-icons").appendingPathComponent("fixture.tiff")
        let icon = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        guard let data = icon.tiffRepresentation else { throw CoverageContext.Failure(description: "Synthetic status icon has no TIFF") }
        try data.write(to: iconURL)
        let app = MonitoredApp(bundleIdentifier: "coverage.status.\(UUID().uuidString)", displayName: "Status fixture", iconPath: iconURL.path)
        f.badges.addApp(app)
        await settle()
        guard let badge = f.items.last, badge !== f.items[0] else { throw CoverageContext.Failure(description: "Badge did not create owned backing") }
        try c.equal(badge.length, 14, "Small badge uses 14-point backing")
        try c.expect(badge.ownedButton.image != nil, "Zero count renders synthetic icon")
        let zeroImage = badge.ownedButton.image
        f.preferencesChanged()
        await settle()
        try c.expect(badge.ownedButton.image === zeroImage, "Unchanged zero count reuses image")
        try c.equal(f.popovers.count, 0, "Initial badge baseline never toasts")
        f.badges.updateBadge(for: app.id, count: 1)
        await settle()
        try c.equal(f.popovers.count, 1, "Badge increase creates one fake-shown popover")
        try c.expect(badge.ownedButton.image !== zeroImage, "Positive count renders new image")
        let countImage = badge.ownedButton.image
        f.preferencesChanged()
        await settle()
        try c.expect(badge.ownedButton.image === countImage, "Count cache avoids rendering again")
        f.badges.updateBadge(for: app.id, count: 3)
        await settle()
        try c.equal(f.popovers.count, 2, "Second increase replaces toast")
        try c.expect(f.dismissals[0].isCancelled, "Replacement cancels old dismiss work")
        try c.equal(f.closedPopovers.count, 1, "Replacement closes old popover")
        f.dismissals.last?.perform()
        try c.equal(f.closedPopovers.count, 2, "Fake scheduled dismiss closes latest popover")
        badge.ownedButton.performClick(nil)
        try c.equal(f.resolvedIDs, [app.id], "Badge action resolves exact bundle ID")
        try c.equal(f.openedApplications, [f.applicationURL], "Badge action opens resolved application through fake")
        f.applicationAvailable = false
        badge.ownedButton.performClick(nil)
        try c.equal(f.openedApplications.count, 1, "Unresolved badge application is not opened")
        f.defaults.set("medium", forKey: Constants.Defaults.badgeIconSize)
        f.preferencesChanged()
        await settle()
        try c.equal(badge.length, 18, "Medium preference updates existing backing width")
        f.defaults.set(true, forKey: Constants.Defaults.hideIconWhenNoNotification)
        f.badges.updateBadge(for: app.id, count: 0)
        await settle()
        try c.expect(f.removed.contains { $0 === badge }, "Zero badge removes hidden backing")
        f.badges.updateBadge(for: app.id, count: 2)
        await settle()
        let recreated = f.items.last!
        try c.expect(recreated !== badge && recreated.ownedButton.image != nil, "Notification recreates hidden backing with image")
        try c.equal(f.runningQueries, 0, "Default badge rendering never queries running applications")
        f.defaults.set(false, forKey: Constants.Defaults.hideIconWhenNoNotification)
        f.defaults.set(true, forKey: Constants.Defaults.hideIconWhenNotRunning)
        f.runningIDs = []
        f.badges.updateBadge(for: app.id, count: 0)
        await settle()
        try c.expect(f.removed.contains { $0 === recreated }, "Not-running zero badge hides backing")
        f.runningIDs = [app.id]
        f.preferencesChanged()
        await settle()
        let running = f.items.last!
        try c.expect(running !== recreated, "Running app with zero unread becomes visible")
        try c.expect(f.runningQueries > 0, "Hide-not-running preference queries injected IDs")
        f.badges.removeApp(app.id)
        await settle()
        try c.expect(f.removed.contains { $0 === running }, "Removing monitored app removes its backing")
        f.badges.addApp(app)
        await settle()
        let gated = f.items.last!
        f.defaults.set(false, forKey: Constants.Defaults.featureBadges)
        f.preferencesChanged()
        await settle()
        try c.expect(f.removed.contains { $0 === gated }, "Badge gate removes all backings")
    }

    private static func shortcutsAndMenu(_ c: CoverageContext, _ f: Fixture) async throws {
        try c.equal(f.handlers.count, 3, "Three fixed shortcuts register only in fake registry")
        f.handlers[.openMenu]?()
        f.handlers[.joinNextMeeting]?()
        try c.expect(f.openedURLs.isEmpty, "Join shortcut with no meeting does nothing")
        f.store.events = [f.event(minutes: 10, url: nil)]
        await f.meetings.refreshEvents()
        await settle()
        f.handlers[.joinNextMeeting]?()
        try c.expect(f.openedURLs.isEmpty, "Join shortcut ignores event without meeting link")
        f.store.events = [f.event(minutes: 10)]
        await f.meetings.refreshEvents()
        await settle()
        f.handlers[.joinNextMeeting]?()
        try c.equal(f.openedURLs, [f.store.events[0].meetingLink!], "Join shortcut uses actual event link")
        f.handlers[.toggleCompanionChat]?()
        try c.equal(f.panelToggles, 0, "Companion shortcut observes disabled feature")
        f.defaults.set(true, forKey: Constants.Defaults.featureCompanion)
        f.handlers[.toggleCompanionChat]?()
        try c.equal(f.panelToggles, 1, "Enabled companion shortcut delegates toggle")

        let menu = f.items[0].menu!
        f.controller.menuWillOpen(menu)
        try invoke("Preferences...", menu, c)
        try c.equal(f.preferenceOpens, 1, "Persistent menu preferences action delegates")
        try invoke("Join Next Meeting", menu, c)
        try c.equal(f.openedURLs.count, 2, "Persistent menu joins event")
        try invoke("Toggle Companion Chat", menu, c)
        try c.equal(f.panelToggles, 2, "Persistent menu toggles companion")
        try invoke("Activate", menu, c)
        try c.expect(f.noSleep.isActive, "Menu activation uses isolated NoSleep manager")
        f.controller.menuWillOpen(menu)
        try invoke("Deactivate", menu, c)
        try c.expect(!f.noSleep.isActive, "Menu deactivation releases isolated NoSleep manager")
        f.controller.menuWillOpen(menu)
        guard let durations = menu.item(withTitle: "Activate for...")?.submenu else {
            throw CoverageContext.Failure(description: "Missing NoSleep duration menu")
        }
        try invoke("Indefinitely", durations, c)
        try c.expect(f.noSleep.timeRemaining.isInfinite, "Duration submenu preserves infinite activation")
        f.noSleep.deactivate()
        try invoke("Quit BusinessBar", menu, c)
        try c.equal(f.quits, 1, "Quit menu action stays at fake boundary")
        f.defaults.set(false, forKey: Constants.Defaults.featureCalendar)
        f.defaults.set(false, forKey: Constants.Defaults.featureNoSleep)
        f.defaults.set(false, forKey: Constants.Defaults.featureCompanion)
        f.controller.menuWillOpen(menu)
        try c.expect(menu.item(withTitle: "Calendar integration disabled") != nil, "Calendar gate reaches menu")
        try c.expect(menu.item(withTitle: "NoSleep disabled") != nil, "NoSleep gate reaches menu")
        try c.expect(menu.item(withTitle: "Toggle Companion Chat") == nil, "Companion gate removes menu action")
        try c.expect(menu.item(withTitle: "Join Next Meeting") == nil, "Calendar gate removes join action")

        let template = PromptTemplate(name: "Status rewrite", prompt: "Rewrite [text]", modelID: UUID())
        let shortcut = KeyboardShortcuts.Name.rewriteTemplate(template.id)
        let deletedID = UUID()
        let deleted = KeyboardShortcuts.Name.rewriteTemplate(deletedID)
        f.defaults.set(Data(), forKey: "KeyboardShortcuts_" + KeyboardShortcuts.Name.templateShortcutPrefix + deletedID.uuidString)
        let unassigned = PromptTemplate(name: "No shortcut", prompt: "Unused")
        f.templates = [template, unassigned]
        f.assignedShortcuts.insert(shortcut)
        f.notifications.post(name: TemplateStore.didChangeNotification, object: nil)
        try c.expect(f.clearedShortcuts.contains(deleted), "Deleted template shortcut assignment is cleared")
        try c.expect(f.removedHandlers.contains(shortcut), "Sync removes previous handler before registration")
        try c.expect(f.handlers[shortcut] != nil, "Assigned template registers handler")
        try c.expect(f.handlers[.rewriteTemplate(unassigned.id)] == nil, "Unassigned template never registers callback")
        f.handlers[shortcut]?()
        try c.equal(f.clientRequests.count, 0, "Disabled companion prevents client lookup")
        f.defaults.set(true, forKey: Constants.Defaults.featureCompanion)
        f.handlers[shortcut]?()
        try c.equal(f.clientRequests, [template.modelID], "Template passes selected model to fake client factory")
        try c.expect(f.rewrites.isEmpty && f.toastMessages.isEmpty, "Missing client prevents toast and rewrite")
        f.clientAvailable = true
        f.handlers[shortcut]?()
        try c.equal(f.rewrites.map(\.id), [template.id], "Available client reaches rewrite boundary")
        try c.equal(f.toastMessages, ["Rewriting with Status rewrite…"], "Successful rewrite emits exact toast")
        f.templates = []
        f.handlers[shortcut]?()
        try c.equal(f.rewrites.count, 1, "Handler rereads templates before starting rewrite")
        f.templates = [template]
        f.notifications.post(name: TemplateStore.didChangeNotification, object: nil)
        f.handlers[shortcut]?()
        try c.equal(f.rewrites.count, 2, "Resync keeps one replacement callback")
    }

    private static func invoke(_ title: String, _ menu: NSMenu, _ c: CoverageContext) throws {
        guard let item = menu.item(withTitle: title), let action = item.action else {
            throw CoverageContext.Failure(description: "Missing menu action \(title)")
        }
        try c.expect(NSApp.sendAction(action, to: item.target, from: item), "Menu dispatch handles \(title)")
    }

    private final class Backing: StatusItemBacking {
        let ownedButton = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        var button: NSButton? { ownedButton }
        var menu: NSMenu?
        var length: CGFloat
        init(_ length: CGFloat) { self.length = length }
    }

    private final class Store: EventStoreProtocol {
        var events: [CalendarEvent] = []
        func requestAccess() async throws -> Bool { false }
        func fetchCalendars() async throws -> [MBCalendar] { [.init(id: "status", title: "Status", color: "#228844", source: "Fixture")] }
        func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] { events }
    }

    private final class Monitor: BadgeMonitoring {
        var onBadgeUpdate: ((String, Int) -> Void)?
        func startMonitoring(apps: [MonitoredApp]) {}
        func stopMonitoring() {}
        func updateAppElements(for apps: [MonitoredApp]) {}
        func restartPollTimer() {}
    }

    private struct Client: LLMClient {
        let name = "Status fixture"
        func stream(messages: [ChatMessage], onToolCall: ((String, String) async -> String)?, reasoningEffortOverride: String?) async -> AsyncThrowingStream<CompanionEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let notifications = NotificationCenter()
        let store = Store()
        let now = Date()
        let meetings: MeetingManager
        let badges: BadgeManager
        let noSleep: NoSleepManager
        var controller: StatusBarController!
        var items: [Backing] = []
        var removed: [Backing] = []
        var timers: [Timer] = []
        var timerIntervals: [TimeInterval] = []
        var handlers: [KeyboardShortcuts.Name: () -> Void] = [:]
        var assignedShortcuts: Set<KeyboardShortcuts.Name> = []
        var clearedShortcuts: [KeyboardShortcuts.Name] = []
        var removedHandlers: [KeyboardShortcuts.Name] = []
        var templates: [PromptTemplate] = []
        var runningIDs: Set<String> = []
        var runningQueries = 0
        var popovers: [NSPopover] = []
        var closedPopovers: [NSPopover] = []
        var dismissals: [DispatchWorkItem] = []
        var resolvedIDs: [String] = []
        var openedApplications: [URL] = []
        var openedURLs: [URL] = []
        var applicationAvailable = true
        let applicationURL = URL(fileURLWithPath: "/coverage/status.app")
        var panelToggles = 0
        var preferenceOpens = 0
        var quits = 0
        var clientRequests: [UUID?] = []
        var clientAvailable = false
        var rewrites: [PromptTemplate] = []
        var toastMessages: [String] = []

        init(_ c: CoverageContext) throws {
            defaults = try c.defaults("status")
            defaults.set(true, forKey: Constants.Defaults.featureCalendar)
            defaults.set(true, forKey: Constants.Defaults.featureNoSleep)
            defaults.set(true, forKey: Constants.Defaults.featureBadges)
            defaults.set(false, forKey: Constants.Defaults.hideIconWhenNotRunning)
            defaults.set(false, forKey: Constants.Defaults.hideIconWhenNoNotification)
            defaults.set("small", forKey: Constants.Defaults.badgeIconSize)
            defaults.set(0, forKey: Constants.Defaults.meetingTitleMaxLength)
            defaults.set(0, forKey: Constants.Defaults.timeRoundingThreshold)
            defaults.set("relative", forKey: Constants.Defaults.timeFormat)
            defaults.set(false, forKey: Constants.Defaults.featureCompanion)
            let fixedNow = now
            meetings = MeetingManager(eventStore: store, nowProvider: { fixedNow }, defaults: defaults, notificationCenter: NotificationCenter())
            let unscheduled: (TimeInterval, @escaping () -> Void) -> Timer = { interval, action in
                Timer(timeInterval: interval, repeats: true) { _ in action() }
            }
            badges = BadgeManager(defaults: defaults, notifications: NotificationCenter(), trust: { false }, monitor: Monitor(), schedule: unscheduled, requestPermission: {}, openSettings: { _ in })
            noSleep = NoSleepManager(defaults: defaults, notifications: NotificationCenter(), workspace: NotificationCenter(), trust: { false }, now: { fixedNow }, schedule: unscheduled, activateSleep: { _ in }, deactivateSleep: {}, startActivity: {}, stopActivity: {})
            var effects = StatusBarController.Effects()
            effects.makeStatusItem = { [unowned self] length in let item = Backing(length); items.append(item); return item }
            effects.removeStatusItem = { [unowned self] item in if let item = item as? Backing { removed.append(item) } }
            effects.now = { fixedNow }
            effects.scheduleTimer = { [unowned self] interval, action in
                timerIntervals.append(interval)
                let timer = Timer(timeInterval: interval, repeats: true, block: action)
                timers.append(timer)
                return timer
            }
            effects.registerShortcut = { [unowned self] name, action in handlers[name] = action }
            effects.getShortcut = { [unowned self] name in assignedShortcuts.contains(name) ? KeyboardShortcuts.Shortcut(.a, modifiers: [.command]) : nil }
            effects.removeShortcutHandler = { [unowned self] name in removedHandlers.append(name); handlers.removeValue(forKey: name) }
            effects.setShortcut = { [unowned self] _, name in clearedShortcuts.append(name) }
            effects.loadTemplates = { [unowned self] in templates }
            effects.runningBundleIDs = { [unowned self] in runningQueries += 1; return runningIDs }
            effects.resolveApplication = { [unowned self] id in resolvedIDs.append(id); return applicationAvailable ? applicationURL : nil }
            effects.openApplication = { [unowned self] in openedApplications.append($0) }
            effects.openURL = { [unowned self] in openedURLs.append($0) }
            effects.togglePanel = { [unowned self] in panelToggles += 1 }
            effects.makeClient = { [unowned self] id in clientRequests.append(id); return clientAvailable ? Client() : nil }
            effects.rewrite = { [unowned self] template, _ in rewrites.append(template) }
            effects.toast = { [unowned self] message, _, _ in toastMessages.append(message) }
            effects.showPopover = { [unowned self] popover, _ in popovers.append(popover) }
            effects.closePopover = { [unowned self] in closedPopovers.append($0) }
            effects.scheduleDismiss = { [unowned self] in dismissals.append($0) }
            effects.quit = { [unowned self] in quits += 1 }
            controller = StatusBarController(meetingManager: meetings, badgeManager: badges, noSleepManager: noSleep, defaults: defaults, notifications: notifications, effects: effects, onShowPreferences: { [unowned self] in preferenceOpens += 1 })
        }

        func preferencesChanged() { notifications.post(name: .businessBarPreferencesDidChange, object: nil) }

        func event(minutes: Int, url: URL? = URL(string: "https://zoom.us/j/123456789")) -> CalendarEvent {
            CalendarEvent(id: "status-event", title: "Status planning", startDate: now.addingTimeInterval(Double(minutes) * 60), endDate: now.addingTimeInterval(Double(minutes + 30) * 60), location: nil, notes: nil, url: url, calendar: .init(id: "status", title: "Status", color: "#228844", source: "Fixture"), organizer: nil, attendees: [])
        }
    }
}
