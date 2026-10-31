import AppIntents
import AppKit
import Combine
import EventKit
import SwiftUI
@testable import BusinessBar
import BusinessBarCore

@MainActor
enum AppViewScenarios {
    static func run(_ context: CoverageContext) async throws {
        _ = NSApplication.shared
        var failures: [String] = []
        func run(_ name: String, _ operation: () async throws -> Void) async {
            do {
                try await operation()
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        await run("defaults and labels") { try defaultsAndLabels(context) }
        await run("intents") { try await intents(context) }
        await run("components") { try await components(context) }
        await run("onboarding") { try await onboarding(context) }
        await run("onboarding flow") { try await onboardingFlow(context) }
        await run("appearance") { try await appearance(context) }
        await run("nosleep tails") { try await nosleepTails(context) }
        await run("menus") { try await menus(context) }
        await run("preferences") { try await preferences(context) }
        await run("local models") { try await localModels(context) }
        await run("badges deep") { try await badgesDeep(context) }
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private static func defaultsAndLabels(_ context: CoverageContext) throws {
        let defaults = try context.defaults("view-defaults")
        defaults.registerDefaults()
        try context.equal(defaults.string(forKey: DefaultsKeys.badgeIconSize), "medium", "Registered badge size")
        try context.equal(defaults.string(forKey: DefaultsKeys.calendarProvider), CalendarProvider.eventKit.rawValue, "Registered provider")
        try context.expect(defaults.bool(forKey: DefaultsKeys.featureCalendar), "Calendar defaults enabled")
        try context.expect(!defaults.bool(forKey: DefaultsKeys.noSleepActivateOnStart), "NoSleep does not activate on startup by default")
        try context.expect(Color(hex: " #12abEF ") != nil, "Hex color accepts whitespace and hash")
        try context.expect(Color(hex: "112233") != nil, "Hex color accepts bare RGB")
        for invalid in ["", "fff", "1234567", "zzzzzz"] {
            try context.expect(Color(hex: invalid) == nil, "Reject invalid color \(invalid)")
        }
        let descriptions = ["DEBUG", "INFO", "WARNING", "ERROR", "FATAL"]
        let userDescriptions = ["Debug (verbose)", "Info", "Warning", "Error", "Fatal only"]
        for (index, level) in LogLevel.allCases.enumerated() {
            try context.equal(level.id, index, "Log identity")
            try context.equal(level.description, descriptions[index], "Diagnostic log label")
            try context.equal(level.userDescription, userDescriptions[index], "Preferences log label")
            try context.expect(level.osLogType.rawValue == [UInt8(2), 1, 0, 16, 17][index], "OS log severity mapping")
        }
        try context.expect(LogLevel.debug < .fatal, "Log severity is ordered")
        try context.equal(PreferencesView.PreferenceTab.allCases.map(\.rawValue), ["General", "Calendars", "Badges", "NoSleep", "Appearance", "Companion"], "Sidebar order")
        try context.equal(PreferencesView.PreferenceTab.allCases.map(\.icon), ["gearshape", "calendar", "app.badge", "cup.and.heat.waves", "paintbrush", "bubble.left.and.text.bubble.right"], "Sidebar symbols")
    }

    private static func intents(_ context: CoverageContext) async throws {
        let event = makeEvent(id: "intent", title: "Coverage planning", location: "Room 3", url: URL(string: "https://zoom.us/j/123456789"))
        var reads = 0
        let disabled = GetNextEventIntent(featureEnabled: { false }, nextEvent: { reads += 1; return event })
        do {
            _ = try await disabled.perform()
            try context.expect(false, "Disabled event intent must throw")
        } catch GetNextEventIntent.IntentError.featureDisabled {
            try context.equal(reads, 0, "Disabled intent does not read calendar")
        }
        do {
            _ = try await GetNextEventIntent(featureEnabled: { true }, nextEvent: { nil }).perform()
            try context.expect(false, "Missing event must throw")
        } catch GetNextEventIntent.IntentError.noEvent {}
        let result = try await GetNextEventIntent(featureEnabled: { true }, nextEvent: { event }).perform()
        try context.expect(result.value?.contains("Coverage planning") == true, "Event intent returns title")
        try context.expect(result.value?.contains("Location: Room 3") == true, "Event intent returns location")
        let noLocation = makeEvent(id: "remote", title: "Remote", location: nil, url: nil)
        let remoteResult = try await GetNextEventIntent(featureEnabled: { true }, nextEvent: { noLocation }).perform()
        try context.expect(remoteResult.value?.contains("Location:") == false, "Absent location is not fabricated")
        var opened: [URL] = []
        do {
            _ = try await JoinNextMeetingIntent(featureEnabled: { false }, nextEvent: { event }, openMeeting: { opened.append($0) }).perform()
            try context.expect(false, "Disabled join must throw")
        } catch JoinNextMeetingIntent.IntentError.featureDisabled {}
        for missing in [nil, Optional(noLocation)] {
            do {
                _ = try await JoinNextMeetingIntent(featureEnabled: { true }, nextEvent: { missing }, openMeeting: { opened.append($0) }).perform()
                try context.expect(false, "Missing meeting link must throw")
            } catch JoinNextMeetingIntent.IntentError.noMeeting {}
        }
        try context.expect(opened.isEmpty, "Rejected joins never open URLs")
        _ = try await JoinNextMeetingIntent(featureEnabled: { true }, nextEvent: { event }, openMeeting: { opened.append($0) }).perform()
        try context.equal(opened, [event.meetingLink!], "Join sends exact meeting URL to boundary")
        var active = false
        var toggles = 0
        let toggle = ToggleNoSleepIntent(featureEnabled: { true }, toggle: { active.toggle(); toggles += 1; return active })
        _ = try await toggle.perform()
        try context.expect(active, "NoSleep activation invokes fake boundary")
        _ = try await toggle.perform()
        try context.expect(!active, "NoSleep deactivation invokes fake boundary")
        do {
            _ = try await ToggleNoSleepIntent(featureEnabled: { false }, toggle: { toggles += 1; return true }).perform()
            try context.expect(false, "Disabled NoSleep intent must throw")
        } catch ToggleNoSleepIntent.IntentError.featureDisabled {}
        try context.equal(toggles, 2, "Disabled NoSleep skips toggle")
        do {
            _ = try await ToggleNoSleepIntent(featureEnabled: { true }, toggle: { throw ToggleNoSleepIntent.IntentError.managerNotAvailable }).perform()
            try context.expect(false, "Unavailable manager must throw")
        } catch ToggleNoSleepIntent.IntentError.managerNotAvailable {}
        try context.equal(String(localized: GetNextEventIntent.IntentError.featureDisabled.localizedStringResource), "Calendar feature is disabled", "Disabled calendar error")
        try context.equal(String(localized: GetNextEventIntent.IntentError.noEvent.localizedStringResource), "No upcoming events found", "No event error")
        try context.equal(String(localized: JoinNextMeetingIntent.IntentError.featureDisabled.localizedStringResource), "Calendar feature is disabled", "Disabled join error")
        try context.equal(String(localized: JoinNextMeetingIntent.IntentError.noMeeting.localizedStringResource), "No upcoming meeting found or meeting has no link", "No link error")
        try context.equal(String(localized: ToggleNoSleepIntent.IntentError.featureDisabled.localizedStringResource), "NoSleep feature is disabled", "Disabled NoSleep error")
        try context.equal(String(localized: ToggleNoSleepIntent.IntentError.managerNotAvailable.localizedStringResource), "NoSleep manager not available", "Unavailable NoSleep error")
        try context.equal(BusinessBarShortcuts.appShortcuts.count, 3, "Three supported shortcuts")
        try context.expect(!GetNextEventIntent.openAppWhenRun && !JoinNextMeetingIntent.openAppWhenRun && !ToggleNoSleepIntent.openAppWhenRun, "Intents do not activate app")
    }

    private static func components(_ context: CoverageContext) async throws {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        for count in [0, 1, 10, 99, 100] {
            for size in [CGFloat(14), 18] {
                let rendered = image.statusBarImage(badgeCount: count, iconSize: size)
                try context.expect(abs(rendered.size.width - size * 1.36) < 0.001 && abs(rendered.size.height - size * 1.36) < 0.001, "Badge image includes overlay extent")
                guard let data = rendered.tiffRepresentation, let pixels = NSBitmapImageRep(data: data) else { throw CoverageContext.Failure(description: "Badge image has no raster representation") }
                let hasRed = (0..<pixels.pixelsWide).contains { x in
                    (0..<pixels.pixelsHigh).contains { y in
                        guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        return color.alphaComponent > 0.5 && color.redComponent > color.blueComponent + 0.2 && color.redComponent > color.greenComponent + 0.2
                    }
                }
                try context.equal(hasRed, count > 0, "Red badge pixels appear only for unread notifications")
                let host = Hosted(BadgeIconView(icon: count % 2 == 0 ? image : nil, badgeCount: count, iconSize: size), size: NSSize(width: 100, height: 70))
                defer { host.close() }
                try host.render(context)
                if count > 0 {
                    try context.expect(host.text.contains(count > 99 ? "99+" : "\(count)"), "Badge bubble count label")
                }
            }
            let toast = Hosted(ToastView(icon: count == 0 ? nil : image, count: count), size: NSSize(width: 160, height: 60))
            defer { toast.close() }
            try toast.render(context)
            try context.expect(toast.text.contains(count > 99 ? "99+" : "\(count)"), "Toast count label")
        }
        var selected: String?
        let app = MonitoredApp(bundleIdentifier: "com.businessbar.coverage.uninstalled", displayName: "Coverage fixture")
        let picker = Hosted(AppPickerView(discoverApps: { [app] }, iconForApp: { _ in nil }, onSelect: { selected = $0.id }), size: NSSize(width: 600, height: 500))
        defer { picker.close() }
        await settle()
        try picker.render(context)
        try picker.press("Coverage fixture", context)
        try context.equal(selected, app.id, "Picker selection calls supplied callback")
        let empty = Hosted(AppPickerView(discoverApps: { [] }, onSelect: { _ in }), size: NSSize(width: 600, height: 500))
        defer { empty.close() }
        await settle()
        try context.expect(empty.text.contains("No apps found"), "Empty discovery is visible")
        let filtered = Hosted(AppPickerView(initialSearchText: "not a match", discoverApps: { [app] }, iconForApp: { _ in nil }, onSelect: { _ in }), size: NSSize(width: 600, height: 500))
        defer { filtered.close() }
        await settle()
        try context.expect(filtered.text.contains("No apps found"), "Search filters installed apps")
        let matched = Hosted(AppPickerView(initialSearchText: "FIXTURE", discoverApps: { [app] }, iconForApp: { _ in nil }, onSelect: { selected = $0.id }), size: NSSize(width: 600, height: 500))
        defer { matched.close() }
        await settle()
        try context.expect(matched.text.contains("Coverage fixture"), "Search is case insensitive")
        let error = Hosted(AppPickerView(discoverApps: { throw FixtureError.discovery }, onSelect: { _ in }), size: NSSize(width: 600, height: 500))
        defer { error.close() }
        await settle()
        try context.expect(error.text.contains("Unable to load apps:"), "Discovery failure is visible")
        let gate = DiscoveryGate()
        let loading = Hosted(AppPickerView(discoverApps: { await gate.wait() }, onSelect: { _ in }), size: NSSize(width: 600, height: 500))
        defer { loading.close() }
        await settle()
        try context.expect(loading.text.contains("Loading apps"), "Pending discovery shows loading state")
        gate.finish()
        await settle()
        try context.expect(loading.text.contains("No apps found"), "Loading resolves to empty state")
        let saved = Hosted(SettingsSavedHost { Text("Preferences fixture") }, size: NSSize(width: 320, height: 120))
        defer { saved.close() }
        var announcements = 0
        let observer = SettingsSavedBus.publisher.sink { announcements += 1 }
        defer { observer.cancel() }
        SettingsSavedBus.announce()
        SettingsSavedBus.announce()
        await settle()
        try context.equal(announcements, 2, "Saved bus emits each preference write")
        try saved.render(context)
        try context.expect(saved.text.contains("Settings saved"), "Saved indicator has accessible label")
    }

    private static func onboarding(_ context: CoverageContext) async throws {
        var next = 0
        let welcome = Hosted(WelcomeStep(onNext: { next += 1 }), size: NSSize(width: 600, height: 550))
        defer { welcome.close() }
        try welcome.render(context)
        try welcome.press("Get Started", context)
        try context.equal(next, 1, "Welcome advances through supplied callback")
        let defaults = try context.defaults("onboarding")
        defaults.set(CalendarProvider.eventKit.rawValue, forKey: Constants.Defaults.calendarProvider)
        let calendar = MBCalendar(id: "calendar", title: "Coverage calendar", color: "#227744", source: "Fixture source")
        var back = 0
        var finished = 0
        var selection: [String] = []
        let step = Hosted(CalendarSelectionStep(onBack: { back += 1 }, onFinish: { finished += 1 }, fetchCalendars: { [calendar] }, persistSelection: { selection = $0 }).defaultAppStorage(defaults), size: NSSize(width: 650, height: 600))
        defer { step.close() }
        await settle()
        try step.render(context)
        try context.expect(step.text.contains("Fixture source") && step.text.contains("Coverage calendar"), "Calendars grouped by source")
        try step.press("Back", context)
        try context.equal(back, 1, "Back invokes callback")
        try step.press("Finish Setup", context)
        try context.equal(selection, [calendar.id], "Finish persists selected calendars")
        try context.equal(finished, 1, "Finish invokes callback")
        let empty = Hosted(CalendarSelectionStep(onBack: {}, onFinish: {}, fetchCalendars: { [] }, persistSelection: { _ in }).defaultAppStorage(defaults), size: NSSize(width: 650, height: 600))
        defer { empty.close() }
        await settle()
        try context.expect(empty.text.contains("No calendars available"), "No calendars state")
        try context.expect(empty.control("Finish Setup")?.isAccessibilityEnabled() == false, "Empty calendar selection cannot finish")
        let failed = Hosted(CalendarSelectionStep(onBack: {}, onFinish: {}, fetchCalendars: { throw FixtureError.discovery }, persistSelection: { _ in }).defaultAppStorage(defaults), size: NSSize(width: 650, height: 600))
        defer { failed.close() }
        await settle()
        try context.expect(failed.text.contains("No calendars available"), "Calendar failure resolves loading")
        defaults.set(CalendarProvider.google.rawValue, forKey: Constants.Defaults.calendarProvider)
        var reads = 0
        let google = Hosted(CalendarSelectionStep(onBack: {}, onFinish: { finished += 1 }, fetchCalendars: { reads += 1; return [] }, persistSelection: { _ in }).defaultAppStorage(defaults), size: NSSize(width: 650, height: 600))
        defer { google.close() }
        await settle()
        try context.expect(google.text.contains("Google Calendar is selected"), "Google onboarding explanation")
        try google.press("Finish Setup", context)
        try context.equal(reads, 0, "Google onboarding never reads local calendars")
        for granted in [false, true] {
            let permissionDefaults = try context.defaults("permissions")
            for key in [Constants.Defaults.featureCalendar, Constants.Defaults.featureNotifications, Constants.Defaults.featureBadges] { permissionDefaults.set(true, forKey: key) }
            var permissionBack = 0
            var permissionFinish = 0
            let permissions = Hosted(PermissionsStep(onBack: { permissionBack += 1 }, onNext: { permissionFinish += 1 }, permissionStatus: { .init(calendar: granted, notifications: granted, accessibility: granted) }).defaultAppStorage(permissionDefaults), size: NSSize(width: 750, height: 900))
            defer { permissions.close() }
            await settle()
            try permissions.render(context)
            for key in [Constants.Defaults.featureCalendar, Constants.Defaults.featureNotifications, Constants.Defaults.featureBadges] {
                try context.equal(permissionDefaults.bool(forKey: key), granted, "Missing permission disables corresponding feature")
            }
            if granted {
                try context.expect(permissions.control("Calendar") != nil, "Calendar toggle has accessible name")
                try context.expect(permissions.control("Meeting Notifications") != nil, "Notification toggle has accessible name")
                try context.expect(permissions.control("Badge Monitoring") != nil, "Badge toggle has accessible name")
            } else {
                try context.expect(permissions.text.contains("Grant Permission"), "Missing permissions show explicit grant controls")
            }
            try permissions.press("Back", context)
            try permissions.press("Finish", context)
            try context.equal(permissionBack, 1, "Permissions Back callback")
            try context.equal(permissionFinish, 1, "Permissions Finish callback")
        }
        for grantAfterRequest in [false, true] {
            let permissionDefaults = try context.defaults("permission-request")
            permissionDefaults.set(false, forKey: Constants.Defaults.featureBadges)
            var accessibilityGranted = false
            var requests = 0
            var events: [String] = []
            let permissions = Hosted(PermissionsStep(
                onBack: {},
                onNext: {},
                permissionStatus: {
                    await Task.yield()
                    events.append("refresh")
                    return .init(calendar: true, notifications: true, accessibility: accessibilityGranted)
                },
                requestAccessibility: {
                    requests += 1
                    events.append("request")
                    accessibilityGranted = grantAfterRequest
                },
                accessibilityRefreshDelay: { events.append("delay") }
            ).defaultAppStorage(permissionDefaults), size: NSSize(width: 750, height: 900))
            defer { permissions.close() }
            await settle()
            try context.expect(permissions.control("Calendar") != nil && permissions.control("Meeting Notifications") != nil, "Only the fake accessibility permission remains ungranted")
            try context.expect(!permissionDefaults.bool(forKey: Constants.Defaults.featureBadges), "Badges start disabled before the permission request")
            try permissions.press("Grant Permission", context)
            await settle()
            try context.equal(requests, 1, "Accessibility grant invokes only its fake request boundary")
            try context.equal(Array(events.suffix(3)), ["request", "delay", "refresh"], "Request waits for delay and the refreshed permission snapshot")
            try context.equal(permissionDefaults.bool(forKey: Constants.Defaults.featureBadges), grantAfterRequest, "Only a completed granted refresh enables badges")
            if grantAfterRequest {
                try context.expect(permissions.control("Badge Monitoring") != nil, "Granted accessibility exposes the named badge toggle")
                try context.expect(!permissions.text.contains("Grant Permission"), "Granted permissions remove the last request control")
            } else {
                try context.expect(permissions.text.contains("Grant Permission"), "Denied accessibility keeps the request available")
            }
        }
    }

    private static func onboardingFlow(_ context: CoverageContext) async throws {
        var flowRequests = 0
        var flowDelays = 0
        let flowStatus: () async -> PermissionsStep.PermissionStatus = {
            .init(calendar: false, notifications: false, accessibility: false)
        }
        // The controller builds the real window; the hosted view carries fake
        // permission boundaries so the bare-binary harness never touches live
        // UNUserNotificationCenter.
        let controller = OnboardingWindowController(onboardingView: OnboardingView(
            permissionStatus: flowStatus,
            requestAccessibility: { flowRequests += 1 },
            accessibilityRefreshDelay: { flowDelays += 1 }
        ))
        try context.expect(controller.window != nil, "Onboarding controller owns a window")
        if let window = controller.window {
            try context.equal(window.title, "Welcome to BusinessBar", "Onboarding window keeps its title")
            try context.expect(window.contentView != nil, "Onboarding window hosts the onboarding view")
            window.orderOut(nil)
            window.close()
        }

        // The full TabView flow: welcome screen first, Get Started advances to
        // the permissions step, Back returns to welcome.
        let flow = Hosted(OnboardingView(
            permissionStatus: flowStatus,
            requestAccessibility: { flowRequests += 1 },
            accessibilityRefreshDelay: { flowDelays += 1 }
        ), size: NSSize(width: 600, height: 500))
        defer { flow.close() }
        await settle()
        try flow.render(context)
        try context.expect(flow.text.contains("Welcome to BusinessBar") || flow.text.contains("Get Started"), "Onboarding flow starts on the welcome step")
        try flow.press("Get Started", context)
        await settle()
        try context.expect(flow.text.contains("Calendar") && flow.text.contains("Badge"), "Onboarding flow advances to permissions step")
        try context.expect(flow.text.contains("Grant Permission"), "Ungranted status renders explicit grant buttons")
        try flow.press("Back", context)
        await settle()
        try context.expect(flow.text.contains("Get Started"), "Back returns to the welcome step")
        try context.equal(flowRequests, 0, "Flow navigation never requests accessibility")

        // Default boundaries: outside an app bundle the live status probe
        // reports notifications as ungranted without UserNotifications, while
        // EventKit and accessibility remain read-only queries.
        let liveDefaults = try context.defaults("onboarding-live")
        liveDefaults.set(true, forKey: Constants.Defaults.featureNotifications)
        liveDefaults.set(true, forKey: Constants.Defaults.featureCalendar)
        liveDefaults.set(true, forKey: Constants.Defaults.featureBadges)
        let live = Hosted(PermissionsStep(onBack: {}, onNext: {}).defaultAppStorage(liveDefaults), size: NSSize(width: 750, height: 900))
        defer { live.close() }
        await settle()
        try live.render(context)
        try context.expect(live.text.contains("Permissions & Features"), "Live status probe renders the permissions step")
        try context.expect(!liveDefaults.bool(forKey: Constants.Defaults.featureNotifications), "Ungranted live notifications clear the feature flag")
        try live.press("Back", context)
        try live.press("Finish", context)
    }

    private static func appearance(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("appearance")
        for scheme in [ColorScheme.light, .dark] {
            for (format, threshold, expected) in [("relative", 0, "in 1h31m"), ("relative", 1, "in 2h"), ("absolute", 3, "(10:00-10:30)"), ("unknown", 3, "in 1h31m")] {
                defaults.set(format, forKey: Constants.Defaults.timeFormat)
                defaults.set(threshold, forKey: Constants.Defaults.timeRoundingThreshold)
                defaults.set(format == "absolute" ? "medium" : "small", forKey: Constants.Defaults.badgeIconSize)
                defaults.set(format != "unknown", forKey: Constants.Defaults.grayscaleWhenNoNotifications)
                let host = Hosted(AppearanceTab().defaultAppStorage(defaults).environment(\.colorScheme, scheme), size: NSSize(width: 800, height: 900))
                defer { host.close() }
                await settle()
                try host.render(context)
                try context.expect(host.text.contains(expected), "Appearance preview for \(format), threshold \(threshold), \(scheme)")
                if format == "relative" {
                    try context.expect(host.text.contains(threshold == 0 ? "Always exact" : "Round when"), "Rounding help follows threshold")
                } else {
                    try context.expect(!host.text.contains("Time rounding threshold:"), "Absolute and unknown formats hide rounding slider")
                }
            }
        }
        for granted in [false, true] {
            defaults.set(true, forKey: Constants.Defaults.noSleepSimulateActivity)
            let host = Hosted(NoSleepTab(accessibilityStatus: { granted }).defaultAppStorage(defaults), size: NSSize(width: 800, height: 1100))
            defer { host.close() }
            await settle()
            try host.render(context)
            try context.expect(host.text.contains(granted ? "Accessibility permission granted" : "Accessibility permission required"), "NoSleep permission status")
            try context.equal(defaults.bool(forKey: Constants.Defaults.noSleepSimulateActivity), granted, "Activity simulation requires permission")
        }
    }

    /// NoSleepTab onChange tails. The pickers bind @AppStorage, so external
    /// defaults writes land through the binding and fire onChange while the
    /// tab is hosted (measured on this host: the grouped Form pickers update
    /// on the next render pass after the write). The tccutil reset and the
    /// System Settings URL stay dark: they touch real system state.
    private static func nosleepTails(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("nosleep-tails")
        defaults.set(true, forKey: Constants.Defaults.featureNoSleep)
        defaults.set(true, forKey: Constants.Defaults.noSleepSimulateActivity)
        var simulateChanged = 0
        var preferencesChanged = 0
        let simulateObserver = NotificationCenter.default.addObserver(
            forName: .noSleepSimulateActivityChanged, object: nil, queue: nil
        ) { _ in simulateChanged += 1 }
        let preferencesObserver = NotificationCenter.default.addObserver(
            forName: .businessBarPreferencesDidChange, object: nil, queue: nil
        ) { _ in preferencesChanged += 1 }
        defer {
            NotificationCenter.default.removeObserver(simulateObserver)
            NotificationCenter.default.removeObserver(preferencesObserver)
        }

        // Granted accessibility: the simulation controls stay enabled.
        let host = Hosted(NoSleepTab(accessibilityStatus: { true }).defaultAppStorage(defaults), size: NSSize(width: 800, height: 1100))
        defer { host.close() }
        await settle()
        try host.render(context)
        try context.expect(host.text.contains("Accessibility permission granted"), "Granted status renders in the tail host")
        try context.expect(host.text.contains("Check every"), "Simulation settings render while granted")

        // Feature toggle: external write fires the preferences-change
        // notification through the binding's onChange.
        let preferencesBefore = preferencesChanged
        defaults.set(false, forKey: Constants.Defaults.featureNoSleep)
        await settle()
        await settle()
        try context.expect(preferencesChanged > preferencesBefore, "Feature toggle posts the preferences-changed notification")
        defaults.set(true, forKey: Constants.Defaults.featureNoSleep)
        await settle()
        await settle()

        // Check interval and idle multiplier: both post the simulate-changed
        // notification (the mapped idle threshold text re-renders too).
        let simulateBefore = simulateChanged
        defaults.set(60, forKey: Constants.Defaults.activityCheckInterval)
        await settle()
        await settle()
        defaults.set(6, forKey: Constants.Defaults.activityIdleMultiplier)
        await settle()
        await settle()
        try context.expect(simulateChanged > simulateBefore, "Interval and multiplier changes post the simulate-changed notification")
        try context.expect(host.text.contains("= 6m"), "Idle threshold text follows the new interval and multiplier")

        // didBecomeActive re-runs the status probe; granted stays granted and
        // the simulation flag survives.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        await settle()
        try context.expect(host.text.contains("Accessibility permission granted"), "Activation re-probe keeps the granted status")
        try context.equal(defaults.bool(forKey: Constants.Defaults.noSleepSimulateActivity), true, "Granted re-probe keeps simulation enabled")
    }

    private static func menus(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("menus")
        defaults.set(true, forKey: Constants.Defaults.featureNoSleep)
        let manager = NoSleepManager(defaults: defaults, notifications: NotificationCenter(), workspace: NotificationCenter(), trust: { false }, schedule: { interval, action in Timer(timeInterval: interval, repeats: false) { _ in action() } }, activateSleep: { _ in }, deactivateSleep: {}, startActivity: {}, stopActivity: {})
        var joined: [String] = []
        var dismissed: [String] = []
        var callbacks: [String] = []
        var durations: [TimeInterval?] = []
        let event = makeEvent(id: "meeting", title: "Menu meeting", location: nil, url: URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        let plain = makeEvent(id: "plain", title: "No meeting URL", location: nil, url: nil)
        func build(events: [CalendarEvent], loading: Bool = false, showEvents: Bool = true, showNoSleep: Bool = true, companion: Bool = true) -> NSMenu {
            MenuBuilder.build(events: events, nextEvent: events.first, isLoading: loading, noSleepManager: manager, onJoinMeeting: { joined.append($0.id) }, onDismissEvent: { dismissed.append($0) }, onToggleNoSleep: { callbacks.append("toggle") }, onActivateNoSleep: { durations.append($0) }, onDeactivateNoSleep: { callbacks.append("deactivate") }, onShowPreferences: { callbacks.append("preferences") }, onQuit: { callbacks.append("quit") }, onToggleCompanionChat: { callbacks.append("chat") }, showEvents: showEvents, showNoSleep: showNoSleep, showCompanion: companion, defaults: defaults)
        }
        let menu = build(events: [event, plain])
        try context.expect(menu.items.contains(where: { $0.title.contains("Menu meeting") && $0.submenu != nil }), "Meeting gets join submenu")
        try context.expect(menu.items.contains(where: { $0.title.contains("No meeting URL") && $0.submenu == nil }), "Non-meeting has no join submenu")
        let handler = MenuActionHandler.shared
        guard let meetingItem = menu.items.first(where: { $0.title.contains("Menu meeting") }), let join = meetingItem.submenu?.item(withTitle: "Join Meeting"), let dismiss = meetingItem.submenu?.item(withTitle: "Dismiss"), let next = menu.item(withTitle: "Join Next Meeting") else {
            throw CoverageContext.Failure(description: "Expected meeting controls missing")
        }
        handler.eventClicked(meetingItem)
        handler.joinMeeting(join)
        handler.joinNextMeeting(next)
        handler.dismissEvent(dismiss)
        try context.equal(joined, [event.id, event.id, event.id], "All join menu routes use callback")
        try context.equal(dismissed, [event.id], "Dismiss carries exact event ID")
        if let plainItem = menu.items.first(where: { $0.title.contains("No meeting URL") }) { handler.eventClicked(plainItem) }
        try context.equal(joined.count, 3, "Click without link does not join")
        guard let activate = menu.item(withTitle: "Activate"), let preferences = menu.item(withTitle: "Preferences..."), let quit = menu.item(withTitle: "Quit BusinessBar"), let chat = menu.item(withTitle: "Toggle Companion Chat"), let durationMenu = menu.item(withTitle: "Activate for...")?.submenu else {
            throw CoverageContext.Failure(description: "Expected app controls missing")
        }
        handler.toggleNoSleep(activate)
        handler.showPreferences(preferences)
        handler.quit(quit)
        handler.toggleCompanionChat(chat)
        for item in durationMenu.items { handler.activateNoSleepFor(item) }
        try context.equal(callbacks, ["toggle", "preferences", "quit", "chat"], "App menu callbacks are isolated")
        try context.equal(durations.count, 13, "Every duration option has an action")
        try context.expect(durations[0] == nil, "First option is indefinite")
        try context.equal(durations.compactMap { $0 }, [900, 1800, 3600, 7200, 10800, 14400, 18000, 21600, 25200, 28800, 43200, 57600], "Menu durations retain exact seconds")
        try context.expect(build(events: [], loading: true).item(withTitle: "Loading events...")?.isEnabled == false, "Loading menu is not actionable")
        try context.expect(build(events: []).item(withTitle: "No upcoming events")?.isEnabled == false, "Empty menu is explicit")
        let tomorrowStart = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(3600)
        let tomorrow = CalendarEvent(id: "tomorrow", title: "Tomorrow fixture", startDate: tomorrowStart, endDate: tomorrowStart.addingTimeInterval(1800), location: nil, notes: nil, url: nil, calendar: event.calendar, organizer: nil, attendees: [])
        defaults.set(true, forKey: Constants.Defaults.showTomorrowEvents)
        try context.expect(build(events: [tomorrow]).items.contains(where: { $0.title.contains("Tomorrow fixture") }), "Tomorrow setting includes next-day event")
        defaults.set(false, forKey: Constants.Defaults.showTomorrowEvents)
        try context.expect(build(events: [tomorrow]).item(withTitle: "No upcoming events") != nil, "Tomorrow setting hides next-day event")
        let disabled = build(events: [event], showEvents: false, showNoSleep: false, companion: false)
        try context.expect(disabled.item(withTitle: "Calendar integration disabled") != nil && disabled.item(withTitle: "NoSleep disabled") != nil, "Feature-disabled menu states")
        try context.expect(disabled.item(withTitle: "Join Next Meeting") == nil && disabled.item(withTitle: "Toggle Companion Chat") == nil, "Disabled features omit actions")
        for duration in [TimeInterval?.none, .some(5400), .some(300)] {
            manager.activate(duration: duration)
            let active = build(events: [])
            guard let deactivate = active.item(withTitle: "Deactivate") else { throw CoverageContext.Failure(description: "Active NoSleep missing deactivate") }
            handler.deactivateNoSleep(deactivate)
            try context.expect(active.items.contains(where: { $0.title.contains("Active") }), "Active duration status is visible")
        }
        let invalid = NSMenuItem(title: "Invalid payload", action: nil, keyEquivalent: "")
        let before = callbacks.count
        handler.joinNextMeeting(invalid)
        handler.joinMeeting(invalid)
        handler.eventClicked(invalid)
        handler.dismissEvent(invalid)
        handler.toggleNoSleep(invalid)
        handler.activateNoSleepFor(invalid)
        handler.deactivateNoSleep(invalid)
        handler.showPreferences(invalid)
        handler.toggleCompanionChat(invalid)
        handler.quit(invalid)
        try context.equal(callbacks.count, before, "Mismatched menu payloads never execute callbacks")
    }

    private static func preferences(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("preferences")
        defaults.registerDefaults()
        defaults.set(false, forKey: Constants.Defaults.featureBadges)
        defaults.set(false, forKey: Constants.Defaults.fileLoggingEnabled)
        let monitor = BadgeBoundary()
        let badges = BadgeManager(defaults: defaults, notifications: NotificationCenter(), trust: { false }, monitor: monitor, requestPermission: {}, openSettings: { _ in })
        let store = CalendarBoundary()
        let meetings = MeetingManager(eventStore: store, defaults: defaults, notificationCenter: NotificationCenter())
        let auth = GoogleAuth(dependencies: .init(loadCredential: { throw FixtureError.discovery }, saveCredential: { _ in }, deleteCredential: {}, configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") }, request: { _ in throw FixtureError.discovery }, openURL: { _ in false }))
        let backend = UpdateBoundary()
        let updater = UpdaterViewModel(backend: backend)
        let oldDefaults = CompanionConfigService.defaults
        let oldCredentials = CompanionConfigService.credentials
        let oldProviderStore = CompanionConfigService.chatProviderStore
        CompanionConfigService.defaults = defaults
        CompanionConfigService.credentials = .init(load: { _ in nil }, save: { _, _ in }, delete: { _ in })
        CompanionConfigService.chatProviderStore = ChatProviderStore(defaults: defaults)
        defer {
            CompanionConfigService.defaults = oldDefaults
            CompanionConfigService.credentials = oldCredentials
            CompanionConfigService.chatProviderStore = oldProviderStore
        }
        var launchEnabled = false
        var launchChanges: [Bool] = []
        let content = PreferencesView.TabContent(
            general: { GeneralTab(launchAtLoginStatus: { launchEnabled }, setLaunchAtLogin: { launchEnabled = $0; launchChanges.append($0) }) },
            calendars: { CalendarsTab(meetingManager: $0, googleAuth: $1, defaults: defaults, calendarAuthorization: { .denied }, notificationAuthorization: { $0(false) }) },
            noSleep: { NoSleepTab(accessibilityStatus: { false }) },
            companion: { CompanionTab(templateStore: TemplateStore(defaults: defaults), accessibilityStatus: { false }) }
        )
        let detailLabels: [PreferencesView.PreferenceTab: String] = [.general: "Launch at login", .calendars: "Enable calendar functionality", .badges: "No apps added yet", .noSleep: "Enable NoSleep functionality", .appearance: "Meeting title max length:", .companion: "Enable Companion"]
        for scheme in [ColorScheme.light, .dark] {
            for tab in PreferencesView.PreferenceTab.allCases {
                let host = Hosted(PreferencesView(badgeManager: badges, meetingManager: meetings, googleAuth: auth, initialTab: tab, tabContent: content).environmentObject(updater).defaultAppStorage(defaults).environment(\.colorScheme, scheme), size: NSSize(width: 1100, height: 1100))
                defer { host.close() }
                await settle()
                try host.render(context)
                try context.expect(host.text.contains(detailLabels[tab]!), "Initial preferences tab renders its own detail: \(tab.rawValue), \(scheme)")
            }
        }
        let general = Hosted(content.general().environmentObject(updater).defaultAppStorage(defaults), size: NSSize(width: 800, height: 1100))
        defer { general.close() }
        await settle()
        try general.press("Launch at login", context)
        await settle()
        try context.equal(launchChanges, [true], "Launch-at-login toggle uses injected boundary")
        try context.expect(launchEnabled, "Launch-at-login reflects boundary state")
        try context.equal(backend.checks, 0, "Rendering preferences never checks updates")
        for level in LogLevel.allCases {
            defaults.set(level.rawValue, forKey: Constants.Defaults.logLevelRaw)
            defaults.set(true, forKey: Constants.Defaults.loggingEnabled)
            await settle()
            let expected = ["High", "Medium", "Very Low", "Minimal", "Minimal"][level.rawValue]
            try context.expect(general.text.contains(expected), "Logging energy label matches level")
        }
        defaults.set(false, forKey: Constants.Defaults.loggingEnabled)
        await settle()
        try context.expect(general.text.contains("None"), "Disabled logging has no energy impact label")
        for interval in [1, 3, 5, 10, 7] {
            defaults.set(interval, forKey: Constants.Defaults.badgePollInterval)
            let badgeHost = Hosted(BadgesTab(badgeManager: badges).defaultAppStorage(defaults), size: NSSize(width: 800, height: 1100))
            defer { badgeHost.close() }
            await settle()
            let expected = [1: "High", 3: "Low", 5: "Very Low", 10: "Minimal"][interval] ?? "Low"
            try context.expect(badgeHost.text.contains(expected), "Badge energy label follows polling frequency")
            try context.expect(badgeHost.text.contains("Accessibility permission required"), "Missing badge permission is explained")
        }
        for status in [EKAuthorizationStatus.notDetermined, .denied, .restricted, .writeOnly, .fullAccess] {
            let calendarHost = Hosted(CalendarsTab(meetingManager: meetings, googleAuth: auth, defaults: defaults, calendarAuthorization: { status }, notificationAuthorization: { $0(true) }).defaultAppStorage(defaults), size: NSSize(width: 800, height: 1300))
            defer { calendarHost.close() }
            await settle()
            try calendarHost.render(context)
            let expected = status == .fullAccess ? "Coverage calendar" : status == .notDetermined ? "Grant calendar permission to select calendars." : "Calendar permission is missing."
            try context.expect(calendarHost.text.contains(expected), "Calendar permission state \(status.rawValue) is visible")
        }
        try context.expect(store.calendarReads > 0, "Calendar pane loads through fake event store")
        try context.equal(monitor.starts, 0, "Disabled badge panes do not start monitoring")
    }

    private static func localModels(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("model-view")
        let home = try context.temporaryDirectory("model-view-home").path
        var processActions = 0
        let driver = MLXProcessDriver(run: { _ in processActions += 1; throw FixtureError.discovery }, isRunning: { _ in false }, terminate: { _ in processActions += 1 }, forceKill: { _ in processActions += 1 }, identifier: { _ in 0 }, registerForQuit: { _ in }, terminationStatus: { _ in 0 })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let server = MLXServerManager(defaults: defaults, home: home, driver: driver, session: session, resolvePython: { _ in throw FixtureError.discovery }, portAvailable: { _ in false }, now: Date.init, sleep: { _ in throw CancellationError() }, residentSize: { _ in 0 }, observeResources: { _ in })
        let store = MLXModelStore(defaults: defaults, home: home, driver: driver, locateUV: { nil }, sleep: { _ in throw CancellationError() })
        for scheme in [ColorScheme.light, .dark] {
            let missing = Hosted(Form { LocalModelsSection(server: server, store: store, defaults: defaults, home: home, locateUV: { nil }) }.environment(\.colorScheme, scheme), size: NSSize(width: 850, height: 600))
            defer { missing.close() }
            await settle()
            try missing.render(context)
            try context.expect(missing.text.contains("Install uv first:"), "Missing local-model prerequisite is explained in both themes")
        }
        var fetches = 0
        let catalog = Hosted(Form {
            LocalModelsSection(server: server, store: store, defaults: defaults, home: home, installedRAM: 1_099_511_627_776, locateUV: { "/fixture/uv" }, fetchDirectory: {
                fetches += 1
                return [.init(id: "fixture/Directory-Model", kind: .text, sizeBytes: 1024, downloads: 7), .init(id: "fixture/Vision-Model", kind: .textAndImages, sizeBytes: nil, downloads: 2)]
            }, inspectRepo: { _ in throw FixtureError.discovery })
        }, size: NSSize(width: 1100, height: 2200))
        defer { catalog.close() }
        await settle()
        try catalog.render(context)
        try context.expect(catalog.text.contains("Pick a model below"), "No selected model has explicit guidance")
        try context.expect(catalog.text.contains(MLXModelCatalog.entries[0].displayName), "Real curated model catalog renders")
        try context.expect(catalog.control("Check")?.isAccessibilityEnabled() == false, "Empty repository cannot be checked")
        try context.equal(fetches, 0, "Rendering model catalog never fetches remote directory")
        try catalog.press("Browse more models", context)
        await settle()
        try context.equal(fetches, 1, "Browse invokes only injected directory boundary")
        try context.expect(catalog.text.contains("Directory Model") || catalog.text.contains("Directory-Model"), "Directory results render their model name")
        try context.expect(catalog.control("Refresh") != nil, "Loaded directory offers refresh")
        let failure = Hosted(Form {
            LocalModelsSection(server: server, store: store, defaults: defaults, home: home, locateUV: { "/fixture/uv" }, fetchDirectory: { throw FixtureError.discovery })
        }, size: NSSize(width: 1100, height: 2200))
        defer { failure.close() }
        await settle()
        try failure.press("Browse more models", context)
        await settle()
        try context.expect(failure.text.contains("Fixture discovery unavailable"), "Directory errors are visible and do not leave loading active")
        try context.expect(failure.control("Browse more models")?.isAccessibilityEnabled() == true, "Failed directory fetch can retry")
        try context.equal(processActions, 0, "Model views never start, stop, download or kill a process")
        try context.equal(server.state, .stopped, "Rendering preserves stopped server state")
        try context.expect(store.download == nil, "Rendering never creates a model download")
    }

    private static func badgesDeep(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("badges-deep")
        var requests = 0
        var settingsOpens = 0
        let monitor = BadgeBoundary()
        let badges = BadgeManager(
            defaults: defaults, notifications: NotificationCenter(), trust: { true }, monitor: monitor,
            schedule: { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } },
            requestPermission: { requests += 1 },
            openSettings: { _ in settingsOpens += 1 }
        )
        // Granted-permission branch of the tab.
        let grantedHost = Hosted(BadgesTab(badgeManager: badges).defaultAppStorage(defaults), size: NSSize(width: 800, height: 1100))
        defer { grantedHost.close() }
        await settle()
        try grantedHost.render(context)
        try context.expect(grantedHost.text.contains("Accessibility permission granted"), "Granted badge permission is confirmed")
        try context.expect(!grantedHost.text.contains("Accessibility permission required"), "Granted state hides the warning")

        // Monitored-app rows: badge count, display name and removal. Rows
        // live in a SwiftUI List (NSTableView-backed, lazy) whose contents
        // never materialize in the owned-AX walk, so the manager is the truth:
        // add, verify contents, remove through the same API the row's trash
        // button calls, and keep AX assertions on the chrome that does render.
        badges.addApp(MonitoredApp(bundleIdentifier: "coverage.badges.one", displayName: "Fixture One", badgeCount: 3))
        badges.addApp(MonitoredApp(bundleIdentifier: "coverage.badges.two", displayName: "Fixture Two"))
        await settle()
        try context.expect(badges.monitoredApps.contains { $0.bundleIdentifier == "coverage.badges.one" && $0.displayName == "Fixture One" }, "Manager lists the first app")
        try context.expect(badges.monitoredApps.contains { $0.bundleIdentifier == "coverage.badges.two" && $0.displayName == "Fixture Two" }, "Manager lists the second app")
        try context.expect(badges.monitoredApps.first { $0.bundleIdentifier == "coverage.badges.one" }?.badgeCount == 3, "Nonzero badge count stored with the row")
        try context.expect(!grantedHost.text.contains("No apps added yet"), "Nonempty list hides the placeholder")
        badges.removeApp("coverage.badges.one")
        await settle()
        try context.expect(!badges.monitoredApps.contains { $0.bundleIdentifier == "coverage.badges.one" }, "Row removal deletes the monitored app")
        try context.expect(badges.monitoredApps.contains { $0.bundleIdentifier == "coverage.badges.two" }, "Other rows survive removal")

        // Add App with permission granted opens the discovery sheet flow.
        try grantedHost.press("Add App", context)
        await settle()
        try context.expect(badges.monitoredApps.contains { $0.bundleIdentifier == "coverage.badges.two" }, "Other rows survive Add App")

        // Ungranted state through a fresh manager: request and settings
        // callbacks route to the injected boundary, not real TCC.
        let deniedDefaults = try context.defaults("badges-denied")
        let denied = BadgeManager(
            defaults: deniedDefaults, notifications: NotificationCenter(), trust: { false }, monitor: monitor,
            schedule: { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } },
            requestPermission: { requests += 1 },
            openSettings: { _ in settingsOpens += 1 }
        )
        let deniedHost = Hosted(BadgesTab(badgeManager: denied).defaultAppStorage(deniedDefaults), size: NSSize(width: 800, height: 1100))
        defer { deniedHost.close() }
        await settle()
        try deniedHost.render(context)
        try deniedHost.press("Open System Settings", context)
        try deniedHost.press("Request Permission", context)
        try context.equal(requests, 1, "Request Permission uses the injected request boundary")
        try context.equal(settingsOpens, 1, "Open System Settings uses the injected settings boundary")
        // Reset Permission runs a real tccutil on the host, so the button is
        // only located, never pressed.
        try context.expect(deniedHost.control("Reset Permission") != nil, "Reset Permission remains present without executing tccutil")

        // Feature toggle wiring: disabled panes dim and stays observable.
        deniedDefaults.set(false, forKey: Constants.Defaults.featureBadges)
        await settle()
        try context.expect(deniedHost.control("Add App")?.isAccessibilityEnabled() == false, "Disabled badge feature disables Add App")
        // The granted manager started monitoring once at init (feature on,
        // trusted); the denied manager polls permission instead, and the
        // feature-off flip only stops, so the whole scenario lands on one.
        try context.equal(monitor.starts, 1, "Only the granted manager starts monitoring")
    }

    private static func makeEvent(id: String, title: String, location: String?, url: URL?) -> CalendarEvent {
        let start = Date().addingTimeInterval(-60)
        return CalendarEvent(id: id, title: title, startDate: start, endDate: start.addingTimeInterval(1800), location: location, notes: nil, url: url, calendar: MBCalendar(id: "fixture", title: "Fixture", color: "#227744", source: "Fixture"), organizer: nil, attendees: [])
    }

    private static func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            pumpMainRunLoop()
        }
    }

    private static func pumpMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }

    private enum FixtureError: LocalizedError {
        case discovery
        var errorDescription: String? { "Fixture discovery unavailable" }
    }

    private final class CalendarBoundary: EventStoreProtocol {
        var calendarReads = 0
        func requestAccess() async throws -> Bool { false }
        func fetchCalendars() async throws -> [MBCalendar] {
            calendarReads += 1
            return [.init(id: "preferences", title: "Coverage calendar", color: "#227744", source: "Fixture")]
        }
        func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] { [] }
    }

    private final class BadgeBoundary: BadgeMonitoring {
        var onBadgeUpdate: ((String, Int) -> Void)?
        var starts = 0
        func startMonitoring(apps: [MonitoredApp]) { starts += 1 }
        func stopMonitoring() {}
        func updateAppElements(for apps: [MonitoredApp]) {}
        func restartPollTimer() {}
    }

    private final class UpdateBoundary: UpdaterBackend {
        var automaticallyChecksForUpdates = false
        var canCheckForUpdates = true
        var checks = 0
        func start() throws {}
        func checkForUpdates() { checks += 1 }
    }

    private final class DiscoveryGate {
        private var continuation: CheckedContinuation<[MonitoredApp], Never>?
        func wait() async -> [MonitoredApp] {
            await withCheckedContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(returning: []); continuation = nil }
    }

    @MainActor
    private final class Hosted<Content: View> {
        let host: NSHostingView<Content>
        private let window: NSWindow

        init(_ content: Content, size: NSSize) {
            OwnedAccessibility.materialize()
            host = NSHostingView(rootView: content)
            let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            // Same teardown rule as UI2Hosted: no ordering animations, the
            // transform animation outliving a panel over-releases on
            // dealloc (measured run12 segfault).
            panel.animationBehavior = .none
            panel.alphaValue = 0
            window = panel
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            window.orderFront(nil)
            host.displayIfNeeded()
        }

        var elements: [OwnedAccessibility.Element] {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            return OwnedAccessibility.elements(in: host)
        }

        var text: String {
            host.layoutSubtreeIfNeeded()
            return elements.flatMap { element in
                [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
            }.joined(separator: "\n")
        }

        func control(_ name: String) -> OwnedAccessibility.Element? {
            elements.first { element in
                element.accessibilityLabel() == name || element.accessibilityTitle() == name || (element.accessibilityValue() as? String) == name
            }
        }

        func press(_ name: String, _ context: CoverageContext) throws {
            let pressableRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSwitch"]
            let matching = elements.filter { element in
                element.accessibilityLabel() == name || element.accessibilityTitle() == name || (element.accessibilityValue() as? String) == name
            }
            guard !matching.isEmpty else { throw CoverageContext.Failure(description: "Owned control not found: \(name). Tree: \(text)") }
            let enabled = matching.filter { $0.isAccessibilityEnabled() }
            try context.expect(!enabled.isEmpty, "Control is enabled: \(name)")
            // Press named controls directly: buttons and other labeled
            // controls carry their own press action.
            let pressable = enabled.filter { element in
                guard let role = element.accessibilityRole() as? String else { return false }
                return pressableRoles.contains(role)
            }
            if pressable.contains(where: { $0.accessibilityPerformPress() }) { return }
            // macOS Form rows expose the row label as a static-text node with
            // the pressable control as its next sibling in the accessibility
            // walk; the label node itself cannot handle the press action.
            // SwiftUI checkbox nodes report failure from performPress while
            // still performing the toggle, so success is verified through the
            // control's observable value flip instead of the return value.
            for index in elements.indices.dropLast() {
                let element = elements[index]
                guard (element.accessibilityValue() as? String) == name,
                      element.isAccessibilityEnabled(),
                      (element.accessibilityRole() as? String) == "AXStaticText" else { continue }
                let control = elements[index + 1]
                guard let role = control.accessibilityRole() as? String, pressableRoles.contains(role),
                      control.isAccessibilityEnabled() else { continue }
                let before = control.accessibilityValue()
                _ = control.accessibilityPerformPress()
                let after = elements.first { element in
                    (element.accessibilityValue() as? String) == name && (element.accessibilityRole() as? String) == "AXStaticText" && element.isAccessibilityEnabled()
                }.flatMap { _ in elements[index + 1].accessibilityValue() }
                try context.expect(String(describing: after) != String(describing: before), "Owned control handles press: \(name)")
                return
            }
            try context.expect(false, "Owned control handles press: \(name)")
        }

        func render(_ context: CoverageContext) throws {
            host.layoutSubtreeIfNeeded()
            try context.expect(host.bounds.width > 0 && host.bounds.height > 0, "Hosted geometry is nonempty")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CoverageContext.Failure(description: "Cannot allocate hosted view bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try context.expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Real hosted view renders a bitmap")
            try context.expect(window.alphaValue == 0 && window.frame.maxX < 0 && window.frame.maxY < 0, "Owned scenario panel stays transparent and offscreen")
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            // Drain pending CA transactions before the panel deallocs.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
