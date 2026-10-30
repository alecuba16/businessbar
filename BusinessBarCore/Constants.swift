import Foundation

public extension Notification.Name {
    static let noSleepSimulateActivityChanged = Notification.Name("com.businessbar.noSleepSimulateActivityChanged")
    static let businessBarPreferencesDidChange = Notification.Name("com.businessbar.preferencesDidChange")
}

/// Runtime bundle checks shared by notification and permission entry points.
/// `Bundle.main.bundleIdentifier` is non-nil inside harness binaries that
/// embed an identifier without a real bundle: UserNotifications then aborts
/// with `bundleProxyForCurrentProcess is nil`. Only a packaged .app bundle
/// provides the proxy, so every live UserNotifications call must be gated on
/// `RuntimeBundle.isPresent` instead of the identifier alone.
public enum RuntimeBundle {
    /// True only when the process runs from a packaged .app bundle.
    public static var isPresent: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}

enum Constants {
    static let appName = "BusinessBar"
    static let bundleIdentifier = "com.businessbar.app"
    /// Hosted-view harnesses run from a bare executable; live permission
    /// and notification calls are gated on `RuntimeBundle.isPresent`.
    static var isRuntimeBundlePresent: Bool { RuntimeBundle.isPresent }
    
    enum Defaults {
        static let selectedCalendars = "selectedCalendars"
        static let meetingTitleMaxLength = "meetingTitleMaxLength"
        static let showTomorrowEvents = "showTomorrowEvents"
        static let showDeclinedEvents = "showDeclinedEvents"
        static let notificationMinutesBefore = "notificationMinutesBefore"
        static let endOfEventNotification = "endOfEventNotification"
        static let monitoredApps = "monitoredApps"
        static let hideIconWhenNotRunning = "hideIconWhenNotRunning"
        static let hideIconWhenNoNotification = "hideIconWhenNoNotification"
        static let grayscaleWhenNoNotifications = "grayscaleWhenNoNotifications"
        static let noSleepSleepMode = "noSleepSleepMode"
        static let noSleepDefaultDuration = "noSleepDefaultDuration"
        static let noSleepActivateOnStart = "noSleepActivateOnStart"
        static let noSleepDeactivateOnSleep = "noSleepDeactivateOnSleep"
        static let noSleepSimulateActivity = "noSleepSimulateActivity"
        static let activityCheckInterval = "activityCheckInterval"
        static let activityIdleMultiplier = "activityIdleMultiplier"
        static let badgePollInterval = "badgePollInterval"
        static let badgeIconSize = "badgeIconSize"
        static let timeFormat = "timeFormat"
        static let timeRoundingThreshold = "timeRoundingThreshold"
        // Calendar provider selection ("EventKit" or "Google")
        static let calendarProvider = "calendarProvider"
        static let featureCalendar = "featureCalendar"
        static let featureNoSleep = "featureNoSleep"
        static let featureNotifications = "featureNotifications"
        static let featureBadges = "featureBadges"
    }
    
    enum DefaultValues {
        static let meetingTitleMaxLength = 20
        static let timeRoundingThreshold = 0   // 0 = always show exact (e.g. "1h31m")
        static let notificationMinutesBefore = 5
        static let noSleepDefaultDuration = 0   // 0 = infinite (no time limit)
        static let badgePollInterval = 3             // seconds between badge polls
        static let activityCheckInterval = 30       // seconds between idle checks
        static let activityIdleMultiplier = 3       // fire after N × checkInterval seconds idle
    }
}
