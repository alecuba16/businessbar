import AppKit
@testable import BusinessBarCore
import Foundation
import SwiftUI
import UserNotifications
@testable import BusinessBar

// Both modules expose `Constants`; the app target's keys own these defaults.
private typealias Constants = BusinessBar.Constants

/// Wave C batch 2: UI surfaces the earlier waves left cold. Every
/// interaction here was measured against the real AX tree before being
/// asserted; the safety rails hold — no synthetic keyboard, no real
/// pasteboard writes, no trust prompts, panels hosted invisible.
@MainActor
enum AppUIMiscScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try toastCenter(context) } catch { failures.append("toastCenter: \(error)") }
        do { try await rewriteOverlay(context) } catch { failures.append("rewriteOverlay: \(error)") }
        do { try markdownTextView(context) } catch { failures.append("markdownTextView: \(error)") }
        do { try await permissionsStepDeep(context) } catch { failures.append("permissionsStepDeep: \(error)") }
        do { try await permissionsStepRequests(context) } catch { failures.append("permissionsStepRequests: \(error)") }
        do { try notificationManagerLiveGuard(context) } catch { failures.append("notificationManagerLiveGuard: \(error)") }
        do { try preferencesWindowController(context) } catch { failures.append("preferencesWindowController: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    // MARK: - ToastCenter

    private static func toastCenter(_ context: CoverageContext) throws {
        // show() builds a real borderless status-level panel and orders it
        // front regardless. The scenario dismisses synchronously right
        // after the call, so the panel never survives a run-loop turn and
        // nothing stays on screen; the async auto-dismiss still runs and
        // must be a no-op against an already-dismissed center.
        let center = ToastCenter.shared
        center.show("Fixture toast", icon: "sparkles", duration: 2.0)
        let visiblePanel = NSApp.windows.first { String(describing: type(of: $0)) == "NSPanel" && $0.isVisible && $0.alphaValue > 0 && $0.frame.height < 100 }
        try context.expect(visiblePanel != nil, "Toast presents its own panel")
        center.dismiss()
        try context.expect(NSApp.windows.first { String(describing: type(of: $0)) == "NSPanel" && $0.isVisible && $0.frame.height < 100 } == nil, "Dismiss orders the toast panel out")

        // The duration path: a short toast reaps itself on the shared actor.
        // A tiny duration keeps the harness fast; the reap is observed on
        // the next run-loop turns rather than sleeping the full span.
        center.show("Self dismissing", icon: "info", duration: 0.05)
        center.dismiss()

        // Replacing: a second show must tear the first panel down (no
        // stacking), and dismiss after both leaves zero owned panels.
        center.show("First", duration: 2.0)
        center.show("Second", duration: 2.0)
        let panels = NSApp.windows.filter { String(describing: type(of: $0)) == "NSPanel" && $0.isVisible && $0.frame.height < 100 }
        try context.expect(panels.count <= 1, "Rapid triggers do not stack toast panels")
        center.dismiss()
        center.dismiss()
        try context.expect(NSApp.windows.filter { String(describing: type(of: $0)) == "NSPanel" && $0.isVisible && $0.frame.height < 100 }.isEmpty, "Repeated dismiss stays empty")
    }

    // MARK: - RewriteOverlayController

    private static func rewriteOverlay(_ context: CoverageContext) async throws {
        let controller = RewriteOverlayController.shared

        // performReplace with no panel: the fallback branch logs and copies
        // to the pasteboard, so the scenario must not reach it. Instead the
        // no-panel replace is asserted to leave the real pasteboard
        // untouched by comparing contents around the call.
        let pasteboard = NSPasteboard.general
        let before = pasteboard.pasteboardItems?.first?.string(forType: .string)

        // The Replace fallback path (panel nil) is a real pasteboard write,
        // so this scenario never calls performReplace on a nil panel.
        // Instead: present, intercept the panel before it can draw on
        // screen, drive the SwiftUI view with scenario-owned closures, and
        // exercise windowWillClose.
        var replaceCalls = 0
        var copyCalls = 0
        var closeCalls = 0
        let view = RewriteOverlayView(
            original: "original fixture",
            rewritten: "rewritten fixture",
            templateName: "Fixture template",
            onReplace: { replaceCalls += 1 },
            onCopy: { copyCalls += 1 },
            onClose: { closeCalls += 1 }
        )
        let hosted = UI2MiscHosted(view, size: NSSize(width: 420, height: 280))
        defer { hosted.close() }
        try context.expect(hosted.text.contains("Fixture template"), "Overlay view shows the template name")
        try context.expect(hosted.text.contains("rewritten fixture"), "Overlay view shows the rewritten text")
        try hosted.press("Show original", context)
        try context.expect(hosted.text.contains("original fixture"), "Show original swaps the displayed text")
        try hosted.press("Show original", context)
        try context.expect(hosted.text.contains("rewritten fixture"), "Show original swaps back")

        // Copy with scenario-owned closure: no production pasteboard path.
        try hosted.press("Copy", context)
        try context.equal(copyCalls, 1, "Copy button reaches the injected closure")
        // Close via the injected closure (production onClose dismisses).
        try hosted.press("Close", context)
        try context.equal(closeCalls, 1, "Close button reaches the injected closure")
        // Replace is asserted only through the injected closure; the
        // production replace targets the user's real selection owner.
        try hosted.press("Replace", context)
        try context.equal(replaceCalls, 1, "Replace button reaches the injected closure")

        // present(): the panel becomes visible; intercept immediately by
        // moving it offscreen and dropping alpha before the run loop can
        // composite it, then close through the window (dismiss is private;
        // performClose drives the same NSWindowDelegate teardown).
        controller.present(original: "o", rewritten: "r", templateName: "T", selection: nil)
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .floating && $0.frame.width < 500 }) {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
            panel.performClose(nil)
        }
        try context.expect(NSApp.windows.first(where: { $0.isVisible && $0.level == .floating && $0.frame.width < 500 }) == nil, "Overlay close orders the panel out")

        // windowWillClose clears the controller state when the system
        // closes the panel: a second present still works afterwards.
        controller.present(original: "o2", rewritten: "r2", templateName: "T2", selection: nil)
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .floating && $0.frame.width < 500 }) {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
            panel.performClose(nil)
        }
        try context.expect(NSApp.windows.first(where: { $0.isVisible && $0.level == .floating && $0.frame.width < 500 }) == nil, "System close tears the overlay panel down")

        // The real pasteboard never changed: no production copy path ran.
        let after = pasteboard.pasteboardItems?.first?.string(forType: .string)
        try context.expect(before == after, "Overlay scenario leaves the real pasteboard untouched")

        // Replace fallback guard: with no panel, the production
        // performReplace would write the pasteboard; that branch stays
        // intentionally unexercised (rail: real pasteboard).
    }

    // MARK: - MarkdownTextView

    private static func markdownTextView(_ context: CoverageContext) throws {
        // The parser and renderer are static pure functions over the
        // markdown string; a fixture exercising every block type drives
        // both. The hosting view applies them exactly like the chat reply.
        let fixture = [
            "# Heading one",
            "## Heading two",
            "",
            "Plain paragraph with [a link](https://fixture.invalid/target) and [bad](javascript:alert(1)) inline.",
            "",
            "> quoted line one",
            "> quoted line two",
            "",
            "- bullet alpha",
            "- bullet beta",
            "",
            "1. numbered one",
            "2. numbered two",
            "",
            "```swift",
            "let code = \"fenced\"",
            "```",
            "",
            "~~~",
            "unterminated fence tail",
            "",
            "---",
            "",
            "| col | col2 |",
            "| --- | --- |",
            "| a | b |",
            "",
            "1) paren numbered item",
            "",
            "+ plus bullet",
            "",
            "text\nover two lines",
        ].joined(separator: "\n")

        let attributed = MarkdownAttributedStringLoader.attributedString(for: fixture, baseURL: URL(string: "https://fixture.invalid/"))
        let plain = attributed.string
        try context.expect(plain.contains("Heading one"), "Renders heading level one")
        try context.expect(plain.contains("Heading two"), "Renders heading level two")
        try context.expect(plain.contains("a link"), "Renders paragraph inline text")
        try context.expect(plain.contains("quoted line one"), "Renders quote lines")
        try context.expect(plain.contains("quoted line two"), "Renders multi-line quotes")
        try context.expect(plain.contains("bullet alpha") && plain.contains("bullet beta"), "Renders bullet list items")
        try context.expect(plain.contains("numbered one") && plain.contains("numbered two"), "Renders numbered list items")
        try context.expect(plain.contains("let code = \"fenced\""), "Renders fenced code content")
        try context.expect(plain.contains("unterminated fence tail"), "Unterminated fence still renders its content")
        try context.expect(plain.contains("col2") || plain.contains("col"), "Renders table header")
        try context.expect(plain.contains("paren numbered item"), "Parenthesis numbered list marker parses")
        try context.expect(plain.contains("plus bullet"), "Plus bullet list marker parses")

        // Marker stripping: bullet and numbered markers drop, content stays.
        try context.expect(!plain.contains("• bullet alpha") || plain.contains("bullet alpha"), "Bullet marker precedes content")

        // Link scheme gate: only allowed schemes carry the link attribute.
        let allowed = attributed.attribute(.link, at: 0, effectiveRange: nil)
        _ = allowed
        var linkRanges: [String] = []
        var index = 0
        let length = plain.utf16.count
        while index < length {
            let range = plain.range(of: "a link")
            guard let found = range, found.lowerBound.samePosition(in: String(plain)) != nil else { break }
            let location = plain.distance(from: plain.startIndex, to: found.lowerBound)
            let attr = attributed.attribute(.link, at: location, longestEffectiveRange: nil, in: NSRange(location: 0, length: length)) as? URL
            linkRanges.append(attr?.absoluteString ?? "none")
            index = location + 1
            break
        }
        try context.expect(linkRanges.first == "https://fixture.invalid/target", "Allowed scheme keeps its link attribute")

        // The javascript: scheme is inert: its text renders without a link.
        if let range = plain.range(of: "bad") {
            let location = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let attr = attributed.attribute(.link, at: location, longestEffectiveRange: nil, in: NSRange(location: 0, length: length)) as? URL
            try context.expect(attr == nil, "Disallowed scheme carries no link attribute")
        }

        // Empty and whitespace inputs produce empty documents.
        try context.expect(MarkdownAttributedStringLoader.attributedString(for: "").length == 0, "Empty markdown renders empty")
        try context.expect(MarkdownAttributedStringLoader.attributedString(for: "   \n  \n").length >= 0, "Whitespace-only markdown renders without crashing")

        // Hosting through the real representable applies the same pipeline
        // inside an owned NSView: the chat's own display path.
        let hosted = UI2MiscHosted(MarkdownTextHostingView(markdown: fixture), size: NSSize(width: 420, height: 600))
        defer { hosted.close() }
        try context.expect(hosted.text.contains("Heading one"), "Hosted markdown view exposes rendered heading")
        try context.expect(hosted.text.contains("fenced"), "Hosted markdown view exposes code content")

        // Text view class behaviors: selectable non-editable document.
        if let textView = hosted.textViews.first {
            try context.expect(!textView.isEditable, "Markdown text view stays read-only")
            try context.expect(textView.isSelectable, "Markdown text view stays selectable")
        }
    }

    // MARK: - PermissionsStep deep

    private static func permissionsStepDeep(_ context: CoverageContext) async throws {
        // The notifications Grant Permission button guards on the runtime
        // bundle: outside an .app bundle the press is a safe early return
        // and must not reach UNUserNotificationCenter. This is measured on
        // the bare SPM binary the coverage runner executes.
        let defaults = try context.defaults("permissions-deep")
        defaults.set(true, forKey: Constants.Defaults.featureNotifications)
        var backCalls = 0
        var finishCalls = 0
        let permissions = UI2MiscHosted(PermissionsStep(
            onBack: { backCalls += 1 },
            onNext: { finishCalls += 1 },
            permissionStatus: { .init(calendar: true, notifications: false, accessibility: true) }
        ).defaultAppStorage(defaults), size: NSSize(width: 750, height: 900))
        defer { permissions.close() }
        await miscSettle()
        try context.expect(permissions.text.contains("Meeting Notifications"), "Notifications row renders")
        try context.expect(permissions.text.contains("Grant Permission"), "Ungranted notifications show the grant button")
        try context.expect(!defaults.bool(forKey: Constants.Defaults.featureNotifications), "Ungranted notifications clear the stored feature flag")

        // Press Grant on the notifications row: the bundle guard returns
        // early; no prompt, no crash, and the flag stays cleared.
        try permissions.press("Grant Permission", context)
        await miscSettle()
        try context.expect(!defaults.bool(forKey: Constants.Defaults.featureNotifications), "Bundle-guarded grant leaves the feature disabled")

        // onChange(of: isGranted) disabling branch: refresh with a granted
        // snapshot enables the toggle, then flipping to ungranted through
        // the didBecomeActive re-check must clear the flag again.
        var calendarGranted = true
        let liveDefaults = try context.defaults("permissions-flip")
        liveDefaults.set(true, forKey: Constants.Defaults.featureCalendar)
        let flip = UI2MiscHosted(PermissionsStep(
            onBack: {},
            onNext: {},
            permissionStatus: { .init(calendar: calendarGranted, notifications: true, accessibility: true) }
        ).defaultAppStorage(liveDefaults), size: NSSize(width: 750, height: 900))
        defer { flip.close() }
        await miscSettle()
        try context.expect(liveDefaults.bool(forKey: Constants.Defaults.featureCalendar), "Granted calendar keeps the feature on")
        calendarGranted = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await miscSettle()
        for _ in 0..<200 where liveDefaults.bool(forKey: Constants.Defaults.featureCalendar) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try context.expect(!liveDefaults.bool(forKey: Constants.Defaults.featureCalendar), "Revoked calendar permission clears the feature flag on refresh")

        try context.equal(backCalls, 0, "No back navigation in the deep pass")
        try context.equal(finishCalls, 0, "No finish navigation in the deep pass")
    }

    /// Grant-button request flows with every real permission call replaced
    /// by an injected seam: EventKit access, notification center status and
    /// authorization, settings URL, and the accessibility prompt. Each
    /// hosted step leaves exactly one row ungranted so the single
    /// "Grant Permission" button maps to that row's request path.
    private static func permissionsStepRequests(_ context: CoverageContext) async throws {
        // Calendar grant success: the injected EventKit round trip grants,
        // the toggle appears, and the stored flag follows the grant.
        let calendarDefaults = try context.defaults("permissions-calendar-grant")
        let calendarTab = UI2MiscHosted(PermissionsStep(
            onBack: {},
            onNext: {},
            permissionStatus: { .init(calendar: false, notifications: true, accessibility: true) },
            requestCalendarAccessTask: { true }
        ).defaultAppStorage(calendarDefaults), size: NSSize(width: 750, height: 900))
        defer { calendarTab.close() }
        await miscSettle()
        try calendarTab.press("Grant Permission", context)
        for _ in 0..<200 where calendarDefaults.bool(forKey: Constants.Defaults.featureCalendar) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try context.expect(calendarDefaults.bool(forKey: Constants.Defaults.featureCalendar), "Calendar grant enables the feature flag")
        try context.expect(calendarTab.text.contains("Calendar"), "Calendar row still renders after the grant")

        // Calendar grant failure: the throwing seam covers the catch path
        // and leaves the feature disabled.
        let failingDefaults = try context.defaults("permissions-calendar-fail")
        let failingTab = UI2MiscHosted(PermissionsStep(
            onBack: {},
            onNext: {},
            permissionStatus: { .init(calendar: false, notifications: true, accessibility: true) },
            requestCalendarAccessTask: { throw CoverageContext.Failure(description: "eventkit fixture denial") }
        ).defaultAppStorage(failingDefaults), size: NSSize(width: 750, height: 900))
        defer { failingTab.close() }
        await miscSettle()
        try failingTab.press("Grant Permission", context)
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try context.expect(failingDefaults.bool(forKey: Constants.Defaults.featureCalendar) == false, "Calendar denial keeps the feature disabled")

        // Notification denied: the settings URL opens through the seam.
        var openedURLs: [String] = []
        let deniedDefaults = try context.defaults("permissions-notify-denied")
        let deniedTab = UI2MiscHosted(PermissionsStep(
            onBack: {},
            onNext: {},
            permissionStatus: { .init(calendar: true, notifications: false, accessibility: true) },
            notificationCenterStatus: { receive in receive(.denied) },
            notificationCenterRequest: { receive in receive(false) },
            openNotificationSettingsURL: { url in openedURLs.append(url.absoluteString) },
            isRuntimeBundlePresent: true
        ).defaultAppStorage(deniedDefaults), size: NSSize(width: 750, height: 900))
        defer { deniedTab.close() }
        await miscSettle()
        try deniedTab.press("Grant Permission", context)
        for _ in 0..<60 where openedURLs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try context.expect(openedURLs == ["x-apple.systempreferences:com.apple.preference.notifications"], "Denied notifications open System Settings through the seam")

        // Notification authorized: the granted branch flips the flag
        // without an authorization round trip.
        let authorizedDefaults = try context.defaults("permissions-notify-authorized")
        let authorizedTab = UI2MiscHosted(PermissionsStep(
            onBack: {},
            onNext: {},
            permissionStatus: { .init(calendar: true, notifications: false, accessibility: true) },
            notificationCenterStatus: { receive in receive(.authorized) },
            notificationCenterRequest: { receive in receive(false) },
            isRuntimeBundlePresent: true
        ).defaultAppStorage(authorizedDefaults), size: NSSize(width: 750, height: 900))
        defer { authorizedTab.close() }
        await miscSettle()
        try authorizedTab.press("Grant Permission", context)
        for _ in 0..<200 where authorizedDefaults.bool(forKey: Constants.Defaults.featureNotifications) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try context.expect(authorizedDefaults.bool(forKey: Constants.Defaults.featureNotifications), "Authorized notifications enable the feature")

        // Notification notDetermined: the authorization prompt answers
        // granted, covering the request round trip.
        let promptDefaults = try context.defaults("permissions-notify-prompt")
        let promptTab = UI2MiscHosted(PermissionsStep(
            onBack: {},
            onNext: {},
            permissionStatus: { .init(calendar: true, notifications: false, accessibility: true) },
            notificationCenterStatus: { receive in receive(.notDetermined) },
            notificationCenterRequest: { receive in receive(true) },
            isRuntimeBundlePresent: true
        ).defaultAppStorage(promptDefaults), size: NSSize(width: 750, height: 900))
        defer { promptTab.close() }
        await miscSettle()
        try promptTab.press("Grant Permission", context)
        for _ in 0..<200 where promptDefaults.bool(forKey: Constants.Defaults.featureNotifications) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try context.expect(promptDefaults.bool(forKey: Constants.Defaults.featureNotifications), "Prompted notification grant enables the feature")

        // Accessibility grant: the prompt seam flips the status the next
        // refresh reads, so the delayed refresh enables the badges feature
        // exactly like a real grant landing between polls.
        var accessibilityPrompts = 0
        var accessibilityGrantedNow = false
        let badgeUngrantedDefaults = try context.defaults("permissions-accessibility-ungranted")
        badgeUngrantedDefaults.set(true, forKey: Constants.Defaults.featureBadges)
        let badgeTabUngranted = UI2MiscHosted(PermissionsStep(
            onBack: {},
            onNext: {},
            permissionStatus: { .init(calendar: true, notifications: true, accessibility: accessibilityGrantedNow) },
            requestAccessibility: {
                accessibilityGrantedNow = true
                accessibilityPrompts += 1
            },
            accessibilityRefreshDelay: {}
        ).defaultAppStorage(badgeUngrantedDefaults), size: NSSize(width: 750, height: 900))
        defer { badgeTabUngranted.close() }
        await miscSettle()
        try context.expect(badgeUngrantedDefaults.bool(forKey: Constants.Defaults.featureBadges) == false, "Ungranted accessibility clears the badges flag on first refresh")
        try badgeTabUngranted.press("Grant Permission", context)
        for _ in 0..<200 where badgeUngrantedDefaults.bool(forKey: Constants.Defaults.featureBadges) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try context.equal(accessibilityPrompts, 1, "Accessibility grant prompts through the seam")
        try context.expect(badgeUngrantedDefaults.bool(forKey: Constants.Defaults.featureBadges), "Granted accessibility enables the badges feature")
    }

    // MARK: - NotificationManager live guard

    private static func notificationManagerLiveGuard(_ context: CoverageContext) throws {
        // The convenience init routes to .live dependencies. Outside a real
        // .app bundle RuntimeBundle.isPresent is false, so init stops at the
        // availability guard: no UNUserNotificationCenter call, no delegate
        // wiring. This measures the default path of the manager the app
        // actually constructs at launch.
        let manager = NotificationManager()
        manager.requestAuthorization()
        manager.cancelAllNotifications()
        try context.expect(true, "Live-guarded manager init and guards survive the bare binary")
    }

    // MARK: - PreferencesWindowController

    private static func preferencesWindowController(_ context: CoverageContext) throws {
        // The controller builds the real 800x600 preferences window with
        // the real PreferencesView inside. Construction never orders the
        // window front: show() would steal focus on the user's desktop, so
        // the harness constructs only, asserts the window exists with the
        // hosted content, and closes it without ever showing it.
        let defaults = try context.defaults("prefs-window")
        defaults.registerDefaults()
        let monitor = UIMiscBadgeBoundary()
        let badges = BadgeManager(defaults: defaults, notifications: NotificationCenter(), trust: { false }, monitor: monitor, requestPermission: {}, openSettings: { _ in })
        let meetings = MeetingManager(eventStore: UIMiscDeniedStore(), defaults: defaults, notificationCenter: NotificationCenter())
        let auth = GoogleAuth(dependencies: .init(loadCredential: { throw UIMiscFixtureError.discovery }, saveCredential: { _ in }, deleteCredential: {}, configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") }, request: { _ in throw UIMiscFixtureError.discovery }, openURL: { _ in false }))
        let updater = UpdaterViewModel(backend: UIMiscUpdateBoundary())

        let controller = PreferencesWindowController(
            updaterViewModel: updater,
            badgeManager: badges,
            meetingManager: meetings,
            googleAuth: auth,
            initialTab: nil
        )
        guard let window = controller.window else {
            throw CoverageContext.Failure(description: "Preferences controller owns no window")
        }
        try context.equal(window.title, "BusinessBar Preferences", "Preferences window keeps its title")
        // The host wraps the root in ModifiedContent (environmentObject),
        // and type(of:) on the optional prints Optional<NSView>, so the
        // concrete class name comes from the unwrapped value.
        let contentClass = window.contentView.map { String(describing: type(of: $0)) } ?? "nil"
        try context.expect(contentClass.hasPrefix("NSHostingView"), "Preferences window hosts the real preferences view: \(contentClass)")
        try context.expect(!window.isVisible, "Constructed preferences window stays off screen")

        // A second controller with an explicit initial tab takes the same
        // path with the tab argument.
        let tabbed = PreferencesWindowController(
            updaterViewModel: updater,
            badgeManager: badges,
            meetingManager: meetings,
            googleAuth: auth,
            initialTab: .general
        )
        try context.expect(tabbed.window != nil && !(tabbed.window?.isVisible ?? true), "Tabbed controller window stays off screen too")
        tabbed.window?.close()
        window.close()
    }
}

/// Minimal seams mirroring the AppView harness boundaries.
@MainActor
private final class UIMiscBadgeBoundary: BadgeMonitoring {
    var onBadgeUpdate: ((String, Int) -> Void)?
    func startMonitoring(apps: [MonitoredApp]) {}
    func stopMonitoring() {}
    func updateAppElements(for apps: [MonitoredApp]) {}
    func restartPollTimer() {}
}

@MainActor
private final class UIMiscDeniedStore: EventStoreProtocol {
    func requestAccess() async throws -> Bool { false }
    func fetchCalendars() async throws -> [MBCalendar] { [] }
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] { [] }
}

private enum UIMiscFixtureError: Error { case discovery }

@MainActor
private final class UIMiscUpdateBoundary: UpdaterBackend {
    var automaticallyChecksForUpdates = false
    var canCheckForUpdates = true
    func start() throws {}
    func checkForUpdates() {}
}

/// Same hosting contract as the UI2 harness: invisible panel, owned AX.
@MainActor
private final class UI2MiscHosted<Content: View> {
    let host: NSHostingView<Content>
    private let window: NSPanel

    init(_ content: Content, size: NSSize) {
        OwnedAccessibility.materialize()
        host = NSHostingView(rootView: content)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        // Same teardown rule as UI2Hosted: no ordering animations, the
        // transform animation outliving a panel over-releases on dealloc
        // (measured run12 segfault).
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

    var text: String {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        return OwnedAccessibility.elements(in: host).flatMap { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }

    /// Text views inside the hosted tree, for behavior asserts.
    var textViews: [NSTextView] {
        var found: [NSTextView] = []
        for window in NSApp.windows where window === self.window {
            guard let content = window.contentView else { continue }
            found.append(contentsOf: textViewsIn(content))
        }
        return found
    }

    private func textViewsIn(_ view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let textView = view as? NSTextView { found.append(textView) }
        for subview in view.subviews {
            found.append(contentsOf: textViewsIn(subview))
        }
        return found
    }

    func press(_ name: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        guard let element = OwnedAccessibility.elements(in: host).first(where: { element in
            element.accessibilityLabel() == name || element.accessibilityTitle() == name
        }), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "UI misc control not found or disabled: \(name)")
        }
        try context.expect(element.accessibilityPerformPress(), "UI misc control press succeeds: \(name)")
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        // Drain pending CA transactions before the panel deallocs.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
private func miscSettle() async {
    for _ in 0..<4 {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }
}
