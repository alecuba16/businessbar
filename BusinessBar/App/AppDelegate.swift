import AppKit
import BusinessBarCore
import Combine
import Carbon
import KeyboardShortcuts
import os.log

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Managers
    private var statusBarController: StatusBarController?
    private var meetingManager: MeetingManager?
    private var badgeManager: BadgeManager?
    private var noSleepManager: NoSleepManager?
    private var notificationManager: NotificationManager?

    // MARK: - Services
    private(set) var googleAuth = GoogleAuth()
    private(set) var updaterViewModel = UpdaterViewModel()

    // MARK: - Windows
    private var preferencesWindowController: PreferencesWindowController?
    private var onboardingWindowController: OnboardingWindowController?

    // Backing managers for the SwiftUI Settings scene. Created lazily so a
    // first launch does not pay for them before managers initialize.
    private lazy var lazyBadgeManager = BadgeManager()
    private lazy var lazyMeetingManager = MeetingManager(eventStore: EKEventStoreAdapter())

    /// Managers handed to the SwiftUI `Settings` scene. Reuse the live
    /// managers when they exist so both windows observe the same state.
    var preferencesBadgeManager: BadgeManager { badgeManager ?? lazyBadgeManager }
    var preferencesMeetingManager: MeetingManager { meetingManager ?? lazyMeetingManager }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Install crash handlers before anything else so unhandled crashes
        // are captured to disk.
        CrashHandler.shared.install()

        AppLogger.info("Application launching", category: "AppDelegate")

        // Register Apple Event handler for URL scheme callbacks (Google OAuth redirect).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(getURLEvent:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        registerDefaults()
        migrateChatShortcutDefault()
        migrateDefaultTemplatesToOutputTags()
        initializeManagers()
        setupStatusBar()
        checkFirstLaunch()

        // Check if the app crashed in the previous session and alert the user.
        CrashHandler.shared.showCrashAlertIfNeeded()

        AppLogger.info("Application launched successfully", category: "AppDelegate")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Async tasks may never run before the process exits, so the kill must
        // be synchronous. Skips the graceful session/cancel round trip.
        ShellExecutor.killAllAtQuit()
        MLXServerManager.killAtQuit()
        MLXModelStore.killAtQuit()
        CompanionConfigService.shutdownACPSync()
    }

    /// Receives URLs routed back to the app via CFBundleURLTypes URL schemes.
    /// Used to complete the Google OAuth flow when the browser redirects to
    /// `com.googleusercontent.apps.{CLIENT_NUMBER}:/oauthredirect?code=...`
    @objc private func handleURLEvent(getURLEvent event: NSAppleEventDescriptor,
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
        UserDefaults.standard.registerDefaults()
    }

    /// Moves the chat panel shortcut to the new Cmd+B default once, but
    /// only for users still on the old default (Cmd+Shift+L). Custom
    /// shortcuts are left untouched.
    private func migrateChatShortcutDefault() {
        let key = "KeyboardShortcuts_" + KeyboardShortcuts.Name.toggleCompanionChat.rawValue
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8),
              let shortcut = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data),
              shortcut == KeyboardShortcuts.Shortcut(.l, modifiers: [.command, .shift]),
              UserDefaults.standard.object(forKey: "companionChatShortcutMigratedToCmdB") == nil
        else { return }
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.b, modifiers: [.command]),
            for: .toggleCompanionChat
        )
        UserDefaults.standard.set(true, forKey: "companionChatShortcutMigratedToCmdB")
    }

    /// Replaces the shipped default templates with the versions that pin
    /// the <output> tag format, once. Stored templates are left alone
    /// unless they are byte-identical to some old default prompt, so user
    /// edits survive the migration.
    private func migrateDefaultTemplatesToOutputTags() {
        guard UserDefaults.standard.object(forKey: "companionTemplatesMigratedToOutputTags") == nil
        else { return }
        UserDefaults.standard.set(true, forKey: "companionTemplatesMigratedToOutputTags")

        let store = TemplateStore()
        let stored = store.load()
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
            store.save(updated)
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
            eventStore = GCEventStoreAdapter(auth: googleAuth)
        } else {
            // Fall back to EventKit if Google credentials aren't configured yet.
            if providerRaw == CalendarProvider.google.rawValue && !GoogleAuthConfig.isConfigured {
                AppLogger.warning("Google Calendar selected but not configured — falling back to EventKit", category: "Calendar")
                UserDefaults.standard.set(CalendarProvider.eventKit.rawValue,
                                          forKey: Constants.Defaults.calendarProvider)
            }
            AppLogger.info("Using EventKit calendar provider", category: "Calendar")
            eventStore = EKEventStoreAdapter()
        }

        meetingManager      = MeetingManager(eventStore: eventStore)
        badgeManager        = BadgeManager()
        noSleepManager      = NoSleepManager()
        notificationManager = NotificationManager()

        notificationManager?.requestAuthorization()
        setupNotificationScheduling()

        // Activate NoSleep on start if configured
        let activateOnStart = UserDefaults.standard.bool(forKey: Constants.Defaults.noSleepActivateOnStart)
        let noSleepFeatureEnabled = UserDefaults.standard.bool(forKey: Constants.Defaults.featureNoSleep)
        AppLogger.info("NoSleep activateOnStart: \(activateOnStart), featureEnabled: \(noSleepFeatureEnabled)", category: "NoSleep")
        if activateOnStart && noSleepFeatureEnabled {
            noSleepManager?.toggle()
        }
    }

    private func setupStatusBar() {
        guard let meetingManager,
              let badgeManager,
              let noSleepManager else { return }

        statusBarController = StatusBarController(
            meetingManager: meetingManager,
            badgeManager: badgeManager,
            noSleepManager: noSleepManager,
            onShowPreferences: { [weak self] in
                self?.showPreferences()
            }
        )
    }

    private func checkFirstLaunch() {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            AppLogger.info("First launch detected — showing onboarding", category: "AppDelegate")
            showOnboarding()
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }

        // If the user has previously added apps to monitor but Accessibility
        // permission has been revoked (or never granted), prompt once on launch
        // after a short delay so the menu bar item is already visible.
        promptForAccessibilityIfNeeded()
    }

    private func promptForAccessibilityIfNeeded() {
        guard let badgeManager else { return }
        guard UserDefaults.standard.bool(forKey: Constants.Defaults.featureBadges) else { return }
        guard !badgeManager.monitoredApps.isEmpty else { return }
        guard !AXIsProcessTrusted() else { return }

        // Delay slightly so the status bar item is visible before the alert
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showAccessibilityPermissionAlert()
        }
    }

    private func showAccessibilityPermissionAlert() {
        AppLogger.warning("Showing accessibility permission alert — monitored apps exist but AX permission not granted", category: "Permissions")
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "BusinessBar needs Accessibility permission to read dock badge counts for your monitored apps.\n\nClick \"Open Settings\" to grant access, then re-launch BusinessBar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            badgeManager?.openAccessibilitySettings()
        }
    }

    // MARK: - Notification scheduling

    private var scheduledEventIDs = Set<String>()

    private func setupNotificationScheduling() {
        guard let meetingManager, let notificationManager else { return }

        meetingManager.$events
            .sink { [weak self, weak notificationManager] _ in
                DispatchQueue.main.async {
                    guard let self, let notificationManager else { return }
                    self.scheduleNotificationsForEvents(meetingManager.events, using: notificationManager)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .businessBarPreferencesDidChange)
            .sink { [weak self, weak meetingManager, weak notificationManager] _ in
                guard let self, let meetingManager, let notificationManager else { return }
                DispatchQueue.main.async {
                    self.scheduleNotificationsForEvents(meetingManager.events, using: notificationManager)
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleNotificationsForEvents(_ events: [CalendarEvent], using notificationManager: NotificationManager) {
        let calendarFeatureEnabled = UserDefaults.standard.bool(forKey: Constants.Defaults.featureCalendar)
        let notificationsFeatureEnabled = UserDefaults.standard.bool(forKey: Constants.Defaults.featureNotifications)
        guard calendarFeatureEnabled && notificationsFeatureEnabled else {
            for eventID in scheduledEventIDs {
                notificationManager.cancelNotifications(for: eventID)
            }
            scheduledEventIDs.removeAll()
            notificationManager.cancelAllNotifications()
            return
        }

        let minutesBefore = UserDefaults.standard.integer(forKey: Constants.Defaults.notificationMinutesBefore)
        let newEventIDs = Set(events.map { $0.id })

        for eventID in scheduledEventIDs.subtracting(newEventIDs) {
            notificationManager.cancelNotifications(for: eventID)
        }

        if minutesBefore > 0 {
            for event in events where !event.isAllDay {
                notificationManager.scheduleNotification(for: event, minutesBefore: minutesBefore)
            }
        }

        let endOfEventEnabled = UserDefaults.standard.bool(forKey: Constants.Defaults.endOfEventNotification)
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
            onboardingWindowController = OnboardingWindowController()
        }
        onboardingWindowController?.show()
    }

    /// Opens the Preferences window. `initialTab` selects the section at
    /// creation time; nil keeps General. A controller created without a tab
    /// keeps whatever section it was left on.
    func showPreferences(initialTab: PreferencesView.PreferenceTab? = nil) {
        if preferencesWindowController == nil {
            let bm = badgeManager ?? BadgeManager()
            let mm = meetingManager ?? MeetingManager(eventStore: EKEventStoreAdapter())
            AppLogger.info("Creating preferences window", category: "AppDelegate")
            preferencesWindowController = PreferencesWindowController(
                updaterViewModel: updaterViewModel,
                badgeManager: bm,
                meetingManager: mm,
                googleAuth: googleAuth,
                initialTab: initialTab
            )
        }

        guard let controller = preferencesWindowController else {
            AppLogger.fatal("Preferences window controller is nil after initialization", category: "AppDelegate")
            let alert = NSAlert()
            alert.messageText = "Could not open Preferences"
            alert.informativeText = "An unexpected error occurred while creating the Preferences window.\n\nPlease check the logs in ~/Library/Logs/BusinessBar/ for details."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        controller.show()
        AppLogger.info("Preferences window shown", category: "AppDelegate")
    }

    // MARK: - App Intent helpers

    func getMeetingManager() -> MeetingManager? { meetingManager }
    func getNoSleepManager() -> NoSleepManager? { noSleepManager }
}
