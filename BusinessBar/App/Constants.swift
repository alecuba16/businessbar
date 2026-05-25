import Foundation

enum Constants {
    static let appName = "BusinessBar"
    static let bundleIdentifier = "com.businessbar.app"
    
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
        // Logging configuration
        static let loggingEnabled = "loggingEnabled"
        static let fileLoggingEnabled = "fileLoggingEnabled"
        static let logLevelRaw = "logLevelRaw"
    }
    
    enum DefaultValues {
        static let meetingTitleMaxLength = 20
        static let timeRoundingThreshold = 0   // 0 = always show exact (e.g. "1h31m")
        static let notificationMinutesBefore = 5
        static let noSleepDefaultDuration = 0   // 0 = infinite (no time limit)
        static let badgePollInterval = 3             // seconds between badge polls
        static let logLevelRaw = 2                   // LogLevel.warning.rawValue — only warnings and above by default
        static let activityCheckInterval = 30       // seconds between idle checks
        static let activityIdleMultiplier = 3       // fire after N × checkInterval seconds idle
    }
}
