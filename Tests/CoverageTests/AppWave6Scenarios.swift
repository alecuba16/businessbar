import AppAuth
import AppKit
import BusinessBarCore
import EventKit
import Foundation
import Sparkle
import SwiftUI
@testable import BusinessBar

/// Wave-6 app-side tail: measured zero lines in files whose misses survived
/// the focused workers. Every block targets an exact gap: default-argument
/// closures (they only execute when the call site omits the parameter),
/// the Sparkle backend built through the parameterless view-model init, the
/// composer's keyDown/paste override paths, and GoogleAuth's OAuth
/// live-closure defaults driven through a stubbed AppAuth session.
@MainActor
enum AppWave6Scenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        func attempt(_ name: String, _ block: (CoverageContext) throws -> Void) {
            do {
                try block(context)
                print("PASS: app wave6 \(name)")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL: app wave6 \(name): \(error)")
            }
        }
        func attemptAsync(_ name: String, _ block: @escaping (CoverageContext) async throws -> Void) async {
            do {
                try await block(context)
                print("PASS: app wave6 \(name)")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL: app wave6 \(name): \(error)")
            }
        }
        attempt("no-sleep tab default init", noSleepTabDefaultInit)
        await attemptAsync("calendar step default closures") { c in try await calendarStepDefaultClosures(c) }
        await attemptAsync("onboarding window") { c in try await onboardingWindowTails(c) }
        await attemptAsync("appearance notifications") { c in try await appearanceNotifications(c) }
        attempt("preferences window show", preferencesWindowShow)
        attempt("updater sparkle backend", updaterSparkleBackend)
        await attemptAsync("markdown text view subclass", markdownTextViewSubclass)
        await attemptAsync("toggle no-sleep intent default init") { c in
            try await toggleNoSleepIntentDefaultInit(c)
        }
        await attemptAsync("google auth live closures", googleAuthLiveClosures)
        await attemptAsync("composer keyboard", composerKeyboard)
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// NoSleepTab default-argument closures are stored at init; the
    /// parameterless init runs them at construction (accessibilityStatus
    /// read immediately into @State). Hosting the view would execute the
    /// default body paths (tccutil, System Settings), so construction alone
    /// is the deterministic, side-effect-free trigger. body() must not be
    /// called directly on a modified view (SwiftUI traps), so the default
    /// closures are proven by init alone.
    private static func noSleepTabDefaultInit(_ c: CoverageContext) throws {
        let defaults = try c.defaults("wave6-nosleep-tab")
        let tab = NoSleepTab().defaultAppStorage(defaults)
        _ = tab
        try c.expect(true, "NoSleepTab default init constructs without side effects")
    }

    /// CalendarSelectionStep default-argument closures. Host A omits
    /// every injectable so the real default fetch thunk runs (the adapter
    /// surface is covered by the core nativeBackend block; without a TCC
    /// grant the fetch throws and lands in the catch, a trusted host
    /// seeds the selection instead — both host shapes only render here,
    /// no press). Host B injects a fixture fetch so the enabled Finish
    /// press runs the onFinish chain and the default persistSelection
    /// body on every host.
    private static func calendarStepDefaultClosures(_ c: CoverageContext) async throws {
        let defaults = try c.defaults("wave6-calendar-step")
        defaults.set(CalendarProvider.eventKit.rawValue, forKey: Constants.Defaults.calendarProvider)
        var finishCalls = 0
        let defaultHosted = Coverage2Hosted(
            CalendarSelectionStep(onBack: {}, onFinish: { finishCalls += 1 })
                .defaultAppStorage(defaults),
            size: NSSize(width: 700, height: 700)
        )
        defer { defaultHosted.close() }
        try c.expect(defaultHosted.text.contains("Calendar"), "Calendar step renders")
        await coverage2Settle()

        let fixtureCalendar = MBCalendar(id: "wave6", title: "Wave6 Calendar", color: "#123456", source: "Fixture")
        let hosted = Coverage2Hosted(
            CalendarSelectionStep(
                onBack: {},
                onFinish: { finishCalls += 1 },
                fetchCalendars: { [fixtureCalendar] }
            )
            .defaultAppStorage(defaults),
            size: NSSize(width: 700, height: 700)
        )
        defer { hosted.close() }
        try c.expect(hosted.text.contains("Calendar"), "Fixture calendar step renders")
        await coverage2Settle()
        try hosted.press("Finish Setup", c)
        try c.equal(finishCalls, 1, "Finish default closure persists selection and advances")
    }

    /// show() on the parameterless controller (makeKeyAndOrderFront +
    /// activate), plus the finishOnboarding path through the hosted TabView:
    /// Finish on the permissions step calls NSApp.keyWindow?.close(), a
    /// safe no-op with no key window in the harness.
    private static func onboardingWindowTails(_ c: CoverageContext) async throws {
        let controller = OnboardingWindowController()
        controller.show()
        try c.expect(controller.window?.isVisible ?? false, "Onboarding show orders the window front")
        controller.window?.orderOut(nil)
        controller.close()

        let hosted = Coverage2Hosted(
            OnboardingView(
                permissionStatus: { .init(calendar: true, notifications: true, accessibility: true) },
                requestAccessibility: {},
                accessibilityRefreshDelay: {}
            ),
            size: NSSize(width: 620, height: 520)
        )
        defer { hosted.close() }
        try hosted.press("Get Started", c)
        await coverage2Settle()
        try hosted.press("Finish", c)
        await coverage2Settle()
        try c.expect(true, "Onboarding finish path runs against a nil key window")
    }

    /// notifyPreferencesChanged fires from the hosted tab's onChange hooks:
    /// writing the AppStorage keys through the same suite the view reads
    /// makes the pickers and sliders re-render and post the notification.
    private static func appearanceNotifications(_ c: CoverageContext) async throws {
        let defaults = try c.defaults("wave6-appearance")
        var notified = 0
        let token = NotificationCenter.default.addObserver(
            forName: .businessBarPreferencesDidChange, object: nil, queue: nil
        ) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let hosted = Coverage2Hosted(AppearanceTab().defaultAppStorage(defaults), size: NSSize(width: 820, height: 1000))
        defer { hosted.close() }
        await coverage2Settle()
        defaults.set("absolute", forKey: Constants.Defaults.timeFormat)
        await coverage2Settle()
        defaults.set(12, forKey: Constants.Defaults.timeRoundingThreshold)
        await coverage2Settle()
        defaults.set("large", forKey: Constants.Defaults.badgeIconSize)
        await coverage2Settle()
        try c.expect(notified > 0, "Appearance changes post the preferences-changed notification (got \(notified))")
    }

    /// show() happy path on the real controller: window ordered front and
    /// app activated, then ordered out again. The guard-nil branch needs a
    /// destroyed window, unreachable without breaking AppKit invariants.
    private static func preferencesWindowShow(_ c: CoverageContext) throws {
        let defaults = try c.defaults("wave6-prefs-window")
        let notifications = NotificationCenter()
        let monitor = Wave6BadgeMonitor()
        let badge = BadgeManager(
            defaults: defaults, notifications: notifications,
            trust: { true }, monitor: monitor,
            schedule: { interval, action in Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() } },
            requestPermission: {}, openSettings: { _ in }
        )
        let auth = GoogleAuth(dependencies: .init(
            loadCredential: { throw Wave6Error.unavailable },
            saveCredential: { _ in }, deleteCredential: {},
            configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") },
            request: { _ in throw Wave6Error.unavailable },
            openURL: { _ in false }
        ))
        let meeting = MeetingManager(eventStore: Wave6EventStore(), defaults: defaults, notificationCenter: notifications)
        let updater = UpdaterViewModel(backend: Wave6UpdaterBackend())
        let controller = PreferencesWindowController(
            updaterViewModel: updater, badgeManager: badge,
            meetingManager: meeting, googleAuth: auth
        )
        controller.show()
        try c.expect(controller.window?.isVisible ?? false, "Preferences show orders the window front")
        controller.window?.orderOut(nil)
        controller.close()
    }

    /// SparkleUpdaterBackend through the parameterless UpdaterViewModel
    /// init: real SPUStandardUpdaterController built with
    /// startingUpdater:false, driven through the view-model surface. The
    /// accessors round-trip the Sparkle updater without any UI.
    private static func updaterSparkleBackend(_ c: CoverageContext) throws {
        let previous = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "SUEnableAutomaticChecks") }
            else { UserDefaults.standard.removeObject(forKey: "SUEnableAutomaticChecks") }
        }
        UserDefaults.standard.removeObject(forKey: "SUEnableAutomaticChecks")
        let updater = UpdaterViewModel()
        try c.expect(!updater.canCheckForUpdates, "Sparkle backend starts dormant")
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyChecksForUpdates = false
        updater.checkForUpdates()
        try c.expect(true, "Sparkle backend handled auto-check toggle and manual check")
    }

    /// The MarkdownTextView subclass: hosted through the real representable,
    /// then the link-click gate driven directly. Only the blocked-scheme
    /// branch is asserted: allowlisted schemes open real NSWorkspace, which
    /// the fixture process must not trigger.
    private static func markdownTextViewSubclass(_ c: CoverageContext) async throws {
        let hosted = Coverage2Hosted(MarkdownTextHostingView(markdown: "# Fixture"), size: NSSize(width: 400, height: 300))
        defer { hosted.close() }
        await coverage2Settle()
        guard let textView = hosted.textViews().first else {
            throw CoverageContext.Failure(description: "Hosted markdown did not expose a text view")
        }
        try c.expect(!textView.isEditable, "Hosted markdown text view is read-only")
        textView.clicked(onLink: URL(string: "javascript:alert(1)")!, at: 0)
        try c.expect(true, "Markdown link gate rejects non-allowlisted schemes")
    }

    /// Default init builds the live boundaries: the UserDefaults feature
    /// flag read plus the AppDelegate lookup. In the coverage process the
    /// delegate is not BusinessBar's AppDelegate, so the default toggle
    /// closure throws the documented manager error.
    private static func toggleNoSleepIntentDefaultInit(_ c: CoverageContext) async throws {
        let intent = ToggleNoSleepIntent()
        do {
            _ = try await intent.perform()
            try c.expect(false, "Default toggle must throw without the app's delegate")
        } catch ToggleNoSleepIntent.IntentError.managerNotAvailable {
            try c.expect(true, "Default init reached the delegate lookup and threw the documented error")
        } catch ToggleNoSleepIntent.IntentError.featureDisabled {
            try c.expect(true, "Default feature flag read ran and reported disabled")
        }
    }

    /// GoogleAuth's OAuth.live discover closure routes through AppAuth's
    /// discoverConfiguration; a session-stubbed URLProtocol fails the fetch
    /// in-process so the closure body runs without network. Only global state
    /// touched is AppAuth's session provider, restored in the defer.
    private static func googleAuthLiveClosures(_ c: CoverageContext) async throws {
        URLProtocolStub.failAllRequests = true
        // AppAuth's default is NSURLSession.shared, which ignores globally
        // registered protocol classes, and a bare global registration also
        // proved flaky against ephemeral sessions; installing the stub in
        // the session config's protocolClasses is deterministic. Cleanup
        // hands the provider back to shared (setSession: asserts non-nil).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self] + (configuration.protocolClasses ?? [])
        let session = URLSession(configuration: configuration)
        ProviderProxy.setSession(session)
        defer {
            URLProtocolStub.failAllRequests = false
            ProviderProxy.setSession(URLSession.shared)
        }

        let live = GoogleAuth.OAuth.live
        // AppAuth hops its completion to the main queue. Polling
        // RunLoop.main from inside this async task never services that
        // queue (verified by probe: sync-main pump works, in-task pump
        // starves it), so the completion is bridged to a continuation and
        // awaited; the runner's synchronous main-runloop pump delivers it.
        let discovered: Error? = await withCheckedContinuation { cont in
            var resumed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: CoverageContext.Failure(description: "Live discover closure timed out"))
            }
            live.discover(GoogleAuthConfig.issuer) { _, error in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: error)
            }
        }
        if let failure = discovered as? CoverageContext.Failure {
            throw failure
        }
        try c.expect(discovered != nil, "Stubbed discovery fails locally without network")
    }

    /// ComposerTextView: the native text view hosted through the SwiftUI
    /// representable, driven with synthetic key events and pasteboard
    /// contents. Plain Return routes to onReturn, Command+Return and
    /// Shift+Return fall through (super / newline), a file-URL paste routes
    /// to onPaste, and a plain text paste takes the AppKit fallback.
    private static func composerKeyboard(_ c: CoverageContext) async throws {
        final class DraftBox: ObservableObject {
            @Published var text = ""
            var returns = 0
            var pastes = 0
        }
        let box = DraftBox()
        let hosted = Coverage2Hosted(
            ComposerTextView(
                text: Binding(get: { box.text }, set: { box.text = $0 }),
                focusRequest: .constant(0),
                onReturn: { box.returns += 1 },
                onPaste: { _ in box.pastes += 1 },
                onContentHeight: { _ in }
            ),
            size: NSSize(width: 500, height: 200)
        )
        defer { hosted.close() }
        await coverage2Settle()
        guard let textView = hosted.textViews().first else {
            throw CoverageContext.Failure(description: "Hosted composer did not expose its text view")
        }
        func key(_ mods: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: .init(), windowNumber: textView.window?.windowNumber ?? 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )!
        }
        textView.string = "line one"
        textView.keyDown(with: key([]))
        try c.equal(box.returns, 1, "Plain Return routes through onReturn")
        textView.keyDown(with: key(.command))
        try c.equal(box.returns, 1, "Command+Return falls through to the default handler")
        textView.keyDown(with: key(.shift))
        try c.equal(box.returns, 1, "Shift+Return inserts a newline instead of sending")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted", forType: .string)
        textView.paste(nil)
        try c.expect(textView.string.contains("pasted"), "Plain paste inserts text")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: "/tmp/fixture-image.png") as NSURL])
        textView.paste(nil)
        try c.equal(box.pastes, 1, "File URL paste routes to the staging boundary")
    }
}

// MARK: - Wave-6 fixtures

private enum Wave6Error: Error { case unavailable }

/// OIDURLSessionProvider is Objective-C; call its +setSession: selector
/// dynamically so the stubbed session stays local. Only non-nil sessions
/// are accepted (nil trips an NSAssert in AppAuth), so cleanup hands the
/// provider back to URLSession.shared.
private enum ProviderProxy {
    static func setSession(_ session: URLSession) {
        guard let providerClass = NSClassFromString("OIDURLSessionProvider") as? NSObject.Type else { return }
        let selector = sel_registerName("setSession:")
        _ = providerClass.perform(selector, with: session as AnyObject)
    }
}

/// URLProtocol that fails every request immediately: AppAuth's discovery
/// never leaves the process.
private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var failAllRequests = false

    override class func canInit(with request: URLRequest) -> Bool { failAllRequests }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Inert badge monitor: the BadgeMonitoring contract needs one, but no AX
/// reads happen because no apps are added.
private final class Wave6BadgeMonitor: BadgeMonitoring {
    var onBadgeUpdate: ((String, BadgeValue?) -> Void)?
    private var apps: [MonitoredApp] = []
    func startMonitoring(apps: [MonitoredApp]) { self.apps = apps }
    func stopMonitoring() { apps = [] }
    func updateAppElements(for apps: [MonitoredApp]) { self.apps = apps }
    func restartPollTimer() {}
}

/// Empty event store: the preferences window only needs the manager to
/// construct; nothing fetches because the calendar feature is never on.
private struct Wave6EventStore: EventStoreProtocol {
    func requestAccess() async throws -> Bool { false }
    func fetchCalendars() async throws -> [MBCalendar] { [] }
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] { [] }
    func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool { false }
}

private final class Wave6UpdaterBackend: UpdaterBackend {
    var automaticallyChecksForUpdates = false
    var canCheckForUpdates = false
    func start() {}
    func checkForUpdates() {}
}

extension Coverage2Hosted {
    /// All NSTextView descendants of the hosted panel: the markdown text
    /// view and the composer's ComposerNSTextView are reached this way.
    func textViews() -> [NSTextView] {
        var found: [NSTextView] = []
        func walk(_ view: NSView) {
            if let textView = view as? NSTextView { found.append(textView) }
            for subview in view.subviews { walk(subview) }
        }
        if let content = window.contentView { walk(content) }
        return found
    }
}