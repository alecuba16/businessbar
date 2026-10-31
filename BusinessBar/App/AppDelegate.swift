import AppKit
import BusinessBarCore
import Combine
import Carbon
import KeyboardShortcuts
import os.log

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct WindowPresentation {
        var show: @MainActor () -> Void
    }

    @MainActor
    struct Dependencies {
        var defaults: UserDefaults
        var notifications: NotificationCenter
        var loadTemplates: @MainActor () -> [PromptTemplate]
        var saveTemplates: @MainActor ([PromptTemplate]) -> Void
        var eventStore: @MainActor (CalendarProvider, GoogleAuth) -> any EventStoreProtocol
        var meeting: @MainActor (any EventStoreProtocol) -> MeetingManager
        var badge: @MainActor () -> BadgeManager
        var noSleep: @MainActor () -> NoSleepManager
        var notification: @MainActor () -> NotificationManager
        var status: @MainActor (MeetingManager, BadgeManager, NoSleepManager, @escaping @MainActor () -> Void) -> AnyObject
        var preferences: @MainActor (UpdaterViewModel, BadgeManager, MeetingManager, GoogleAuth, PreferencesView.PreferenceTab?) -> WindowPresentation?
        var onboarding: @MainActor () -> WindowPresentation
        var activationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
        var installCrash: @MainActor () -> Void
        var crashAlert: @MainActor () -> Void
        var registerURL: @MainActor (AppDelegate) -> Void
        var shortcut: @MainActor (KeyboardShortcuts.Shortcut) -> Void
        var googleConfigured: @MainActor () -> Bool
        var axTrusted: @MainActor () -> Bool
        var permissionAlert: @MainActor () -> Bool
        var preferencesError: @MainActor () -> Void
        var enqueue: @MainActor (@escaping @MainActor () -> Void) -> Void
        var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

        static var live: Dependencies {
            Dependencies(
                defaults: .standard,
                notifications: .default,
                loadTemplates: { TemplateStore().load() },
                saveTemplates: { TemplateStore().save($0) },
                eventStore: { provider, auth in
                    if provider == .google { return GCEventStoreAdapter(auth: auth) }
                    return EKEventStoreAdapter()
                },
                meeting: { MeetingManager(eventStore: $0) },
                badge: { BadgeManager() },
                noSleep: { NoSleepManager() },
                notification: { NotificationManager() },
                status: { meeting, badge, noSleep, preferences in
                    StatusBarController(meetingManager: meeting, badgeManager: badge, noSleepManager: noSleep, onShowPreferences: preferences)
                },
                preferences: { updater, badge, meeting, auth, tab in
                    let controller = PreferencesWindowController(updaterViewModel: updater, badgeManager: badge, meetingManager: meeting, googleAuth: auth, initialTab: tab)
                    return WindowPresentation(show: { controller.show() })
                },
                onboarding: {
                    let controller = OnboardingWindowController()
                    return WindowPresentation(show: { controller.show() })
                },
                activationPolicy: { NSApp.setActivationPolicy($0) },
                installCrash: { CrashHandler.shared.install() },
                crashAlert: { CrashHandler.shared.showCrashAlertIfNeeded() },
                registerURL: { delegate in
                    NSAppleEventManager.shared().setEventHandler(
                        delegate,
                        andSelector: #selector(handleURLEvent(getURLEvent:replyEvent:)),
                        forEventClass: AEEventClass(kInternetEventClass),
                        andEventID: AEEventID(kAEGetURL)
                    )
                },
                shortcut: { KeyboardShortcuts.setShortcut($0, for: .toggleCompanionChat) },
                googleConfigured: { GoogleAuthConfig.isConfigured },
                axTrusted: { AXIsProcessTrusted() },
                permissionAlert: {
                    let alert = NSAlert()
                    alert.messageText = "Accessibility Permission Required"
                    alert.informativeText = "BusinessBar needs Accessibility permission to read dock badge counts for your monitored apps.\n\nClick \"Open Settings\" to grant access, then re-launch BusinessBar."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Later")
                    return alert.runModal() == .alertFirstButtonReturn
                },
                preferencesError: {
                    let alert = NSAlert()
                    alert.messageText = "Could not open Preferences"
                    alert.informativeText = "An unexpected error occurred while creating the Preferences window.\n\nPlease check the logs in ~/Library/Logs/BusinessBar/ for details."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                },
                enqueue: { action in DispatchQueue.main.async { action() } },
                after: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() } }
            )
        }
    }

    private let dependencies: Dependencies
    // MARK: - Managers
    private var statusBarController: AnyObject?
    private var meetingManager: MeetingManager?
    private var badgeManager: BadgeManager?
    private var noSleepManager: NoSleepManager?
    private var notificationManager: NotificationManager?

    // MARK: - Services
    private(set) var googleAuth: GoogleAuth
    private(set) var updaterViewModel: UpdaterViewModel
    private let terminateServices: () -> Void

    override convenience init() {
        self.init(googleAuth: GoogleAuth(), updaterViewModel: UpdaterViewModel(), terminateServices: {
            ShellExecutor.killAllAtQuit()
            MLXServerManager.killAtQuit()
            MLXModelStore.killAtQuit()
            CompanionConfigService.shutdownACPSync()
        })
    }

    convenience init(googleAuth: GoogleAuth, updaterViewModel: UpdaterViewModel, terminateServices: @escaping () -> Void) {
        self.init(googleAuth: googleAuth, updaterViewModel: updaterViewModel, terminateServices: terminateServices, dependencies: .live)
    }

    init(googleAuth: GoogleAuth, updaterViewModel: UpdaterViewModel, terminateServices: @escaping () -> Void, dependencies: Dependencies) {
        self.googleAuth = googleAuth
        self.updaterViewModel = updaterViewModel
        self.terminateServices = terminateServices
        self.dependencies = dependencies
        super.init()
    }

    // MARK: - Windows
    private var preferencesWindowController: WindowPresentation?
    private var onboardingWindowController: WindowPresentation?

    // Backing managers for the SwiftUI Settings scene. Created lazily so a
    // first launch does not pay for them before managers initialize.
    private lazy var lazyBadgeManager = dependencies.badge()
    private lazy var lazyMeetingManager = dependencies.meeting(dependencies.eventStore(.eventKit, googleAuth))

    /// Managers handed to the SwiftUI `Settings` scene. Reuse the live
    /// managers when they exist so both windows observe the same state.
    var preferencesBadgeManager: BadgeManager { badgeManager ?? lazyBadgeManager }
    var preferencesMeetingManager: MeetingManager { meetingManager ?? lazyMeetingManager }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        dependencies.activationPolicy(.accessory)

        // Install crash handlers before anything else so unhandled crashes
        // are captured to disk.
        dependencies.installCrash()

        AppLogger.info("Application launching", category: "AppDelegate")

        // Register Apple Event handler for URL scheme callbacks (Google OAuth redirect).
        dependencies.registerURL(self)

        registerDefaults()
        migrateChatShortcutDefault()
        migrateDefaultTemplatesToOutputTags()
        initializeManagers()
        setupStatusBar()
        checkFirstLaunch()

        // Check if the app crashed in the previous session and alert the user.
        dependencies.crashAlert()

        AppLogger.info("Application launched successfully", category: "AppDelegate")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Async tasks may never run before the process exits, so the kill must
        // be synchronous. Skips the graceful session/cancel round trip.
        terminateServices()
    }

    /// Receives URLs routed back to the app via CFBundleURLTypes URL schemes.
    /// Used to complete the Google OAuth flow when the browser redirects to
    /// `com.googleusercontent.apps.{CLIENT_NUMBER}:/oauthredirect?code=...`
    @objc func handleURLEvent(getURLEvent event: NSAppleEventDescriptor,
                                      replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            AppLogger.warning("Failed to parse URL event", category: "AppDelegate")
            return
        }
        AppLogger.info("Received URL event: \(urlString)", category: "AppDelegate")
        googleAuth.resumeAuthorizationFlow(with: url)
    }

    // MARK: - Setup

    private func registerDefaults() {
        dependencies.defaults.registerDefaults()
    }

    /// Moves the chat panel shortcut to the new Cmd+B default once, but
    /// only for users still on the old default (Cmd+Shift+L). Custom
    /// shortcuts are left untouched.
    private func migrateChatShortcutDefault() {
        let key = "KeyboardShortcuts_" + KeyboardShortcuts.Name.toggleCompanionChat.rawValue
        guard let raw = dependencies.defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let shortcut = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data),
              shortcut == KeyboardShortcuts.Shortcut(.l, modifiers: [.command, .shift]),
              dependencies.defaults.object(forKey: "companionChatShortcutMigratedToCmdB") == nil
        else { return }
        dependencies.shortcut(KeyboardShortcuts.Shortcut(.b, modifiers: [.command]))
        dependencies.defaults.set(true, forKey: "companionChatShortcutMigratedToCmdB")
    }

    /// Replaces the shipped default templates with the versions that pin
    /// the <output> tag format, once. Stored templates are left alone
    /// unless they are byte-identical to some old default prompt, so user
    /// edits survive the migration.
    private func migrateDefaultTemplatesToOutputTags() {
        guard dependencies.defaults.object(forKey: "companionTemplatesMigratedToOutputTags") == nil
        else { return }
        dependencies.defaults.set(true, forKey: "companionTemplatesMigratedToOutputTags")

        let stored = dependencies.loadTemplates()
        let oldPrompts = Set([
            "Improve the writing of the following text. Keep its language, meaning and approximate length. Reply with the improved text only, no commentary.\n\n[placeholder]",
            "Correct grammar and spelling mistakes in the following text. Keep its language and meaning. Reply with the corrected text only, no commentary.\n\n[placeholder]",
            "Rewrite the following text to be as concise as possible without losing information. Keep its language. Reply with the rewritten text only, no commentary.\n\n[placeholder]",
            "Translate the following text to English. Reply with the translation only, no commentary.\n\n[placeholder]"
        ])

        var updated = stored
        for (index, template) in stored.enumerated() where oldPrompts.contains(template.prompt) {
            if let fresh = PromptTemplate.defaults.first(where: { $0.name == template.name }) {
                updated[index] = PromptTemplate(id: template.id, name: template.name, prompt: fresh.prompt)
            }
        }
        if updated != stored {
            dependencies.saveTemplates(updated)
        }
    }

    private func initializeManagers() {
        let providerRaw = UserDefaults.standard.string(forKey: Constants.Defaults.calendarProvider)
            ?? CalendarProvider.eventKit.rawValue

        let useGoogle = providerRaw == CalendarProvider.google.rawValue
                     && GoogleAuthConfig.isConfigured

        let eventStore: EventStoreProtocol
        if useGoogle {
            AppLogger.info("Using Google Calendar provider", category: "Calendar")
            eventStore = dependencies.eventStore(.google, googleAuth)
        } else {
            // Fall back to EventKit if Google credentials aren't configured yet.
            if providerRaw == CalendarProvider.google.rawValue && !dependencies.googleConfigured() {
                AppLogger.warning("Google Calendar selected but not configured — falling back to EventKit", category: "Calendar")
                dependencies.defaults.set(CalendarProvider.eventKit.rawValue,
                                          forKey: Constants.Defaults.calendarProvider)
            }
            AppLogger.info("Using EventKit calendar provider", category: "Calendar")
            eventStore = dependencies.eventStore(.eventKit, googleAuth)
        }

        meetingManager      = dependencies.meeting(eventStore)
        badgeManager        = dependencies.badge()
        noSleepManager      = dependencies.noSleep()
        notificationManager = dependencies.notification()

        notificationManager?.requestAuthorization()
        setupNotificationScheduling()

        // Activate NoSleep on start if configured
        let activateOnStart = dependencies.defaults.bool(forKey: Constants.Defaults.noSleepActivateOnStart)
        let noSleepFeatureEnabled = dependencies.defaults.bool(forKey: Constants.Defaults.featureNoSleep)
        AppLogger.info("NoSleep activateOnStart: \(activateOnStart), featureEnabled: \(noSleepFeatureEnabled)", category: "NoSleep")
        if activateOnStart && noSleepFeatureEnabled {
            noSleepManager?.toggle()
        }
    }

    private func setupStatusBar() {
        guard let meetingManager,
              let badgeManager,
              let noSleepManager else { return }

        statusBarController = dependencies.status(
            meetingManager,
            badgeManager,
            noSleepManager,
            { [weak self] in
                self?.showPreferences()
            }
        )
    }

    private func checkFirstLaunch() {
        let hasLaunchedBefore = dependencies.defaults.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            AppLogger.info("First launch detected — showing onboarding", category: "AppDelegate")
            showOnboarding()
            dependencies.defaults.set(true, forKey: "hasLaunchedBefore")
        }

        // If the user has previously added apps to monitor but Accessibility
        // permission has been revoked (or never granted), prompt once on launch
        // after a short delay so the menu bar item is already visible.
        promptForAccessibilityIfNeeded()
    }

    private func promptForAccessibilityIfNeeded() {
        guard let badgeManager else { return }
        guard dependencies.defaults.bool(forKey: Constants.Defaults.featureBadges) else { return }
        guard !badgeManager.monitoredApps.isEmpty else { return }
        guard !dependencies.axTrusted() else { return }

        // Delay slightly so the status bar item is visible before the alert
        dependencies.after(1.5) { [weak self] in
            self?.showAccessibilityPermissionAlert()
        }
    }

    private func showAccessibilityPermissionAlert() {
        AppLogger.warning("Showing accessibility permission alert — monitored apps exist but AX permission not granted", category: "Permissions")

        if dependencies.permissionAlert() {
            badgeManager?.openAccessibilitySettings()
        }
    }

    // MARK: - Notification scheduling

    private var scheduledEventIDs = Set<String>()

    private func setupNotificationScheduling() {
        guard let meetingManager, let notificationManager else { return }

        meetingManager.$events
            .sink { [weak self, weak notificationManager] _ in
                self?.dependencies.enqueue {
                    guard let self, let notificationManager else { return }
                    self.scheduleNotificationsForEvents(meetingManager.events, using: notificationManager)
                }
            }
            .store(in: &cancellables)

        dependencies.notifications.publisher(for: .businessBarPreferencesDidChange)
            .sink { [weak self, weak meetingManager, weak notificationManager] _ in
                guard let self, let meetingManager, let notificationManager else { return }
                self.dependencies.enqueue {
                    self.scheduleNotificationsForEvents(meetingManager.events, using: notificationManager)
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleNotificationsForEvents(_ events: [CalendarEvent], using notificationManager: NotificationManager) {
        let calendarFeatureEnabled = dependencies.defaults.bool(forKey: Constants.Defaults.featureCalendar)
        let notificationsFeatureEnabled = dependencies.defaults.bool(forKey: Constants.Defaults.featureNotifications)
        guard calendarFeatureEnabled && notificationsFeatureEnabled else {
            for eventID in scheduledEventIDs {
                notificationManager.cancelNotifications(for: eventID)
            }
            scheduledEventIDs.removeAll()
            notificationManager.cancelAllNotifications()
            return
        }

        let minutesBefore = dependencies.defaults.integer(forKey: Constants.Defaults.notificationMinutesBefore)
        let newEventIDs = Set(events.map { $0.id })

        for eventID in scheduledEventIDs.subtracting(newEventIDs) {
            notificationManager.cancelNotifications(for: eventID)
        }

        if minutesBefore > 0 {
            for event in events where !event.isAllDay {
                notificationManager.scheduleNotification(for: event, minutesBefore: minutesBefore)
            }
        }

        let endOfEventEnabled = dependencies.defaults.bool(forKey: Constants.Defaults.endOfEventNotification)
        if endOfEventEnabled {
            for event in events where !event.isAllDay {
                notificationManager.scheduleNotification(for: event, minutesBefore: 0)
            }
        }

        scheduledEventIDs = newEventIDs
    }

    // MARK: - Window management

    private func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = dependencies.onboarding()
        }
        onboardingWindowController?.show()
    }

    /// Opens the Preferences window. `initialTab` selects the section at
    /// creation time; nil keeps General. A controller created without a tab
    /// keeps whatever section it was left on.
    func showPreferences(initialTab: PreferencesView.PreferenceTab? = nil) {
        if preferencesWindowController == nil {
            let bm = badgeManager ?? dependencies.badge()
            let mm = meetingManager ?? dependencies.meeting(dependencies.eventStore(.eventKit, googleAuth))
            AppLogger.info("Creating preferences window", category: "AppDelegate")
            preferencesWindowController = dependencies.preferences(updaterViewModel, bm, mm, googleAuth, initialTab)
        }

        guard let controller = preferencesWindowController else {
            AppLogger.fatal("Preferences window controller is nil after initialization", category: "AppDelegate")
            dependencies.preferencesError()
            return
        }

        controller.show()
        AppLogger.info("Preferences window shown", category: "AppDelegate")
    }

    // MARK: - App Intent helpers

    func getMeetingManager() -> MeetingManager? { meetingManager }
    func getNoSleepManager() -> NoSleepManager? { noSleepManager }
}
