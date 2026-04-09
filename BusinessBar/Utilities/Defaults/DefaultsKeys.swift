import BusinessBarCore
import Foundation

    enum DefaultsKeys {
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let selectedCalendars = Constants.Defaults.selectedCalendars
        static let meetingTitleMaxLength = Constants.Defaults.meetingTitleMaxLength
        static let showTomorrowEvents = Constants.Defaults.showTomorrowEvents
        static let showDeclinedEvents = Constants.Defaults.showDeclinedEvents
        static let notificationMinutesBefore = Constants.Defaults.notificationMinutesBefore
        static let endOfEventNotification = Constants.Defaults.endOfEventNotification
        static let monitoredApps = Constants.Defaults.monitoredApps
        static let hideIconWhenNotRunning = Constants.Defaults.hideIconWhenNotRunning
        static let hideIconWhenNoNotification = Constants.Defaults.hideIconWhenNoNotification
        static let grayscaleWhenNoNotifications = Constants.Defaults.grayscaleWhenNoNotifications
        static let noSleepSleepMode = Constants.Defaults.noSleepSleepMode
        static let noSleepDefaultDuration = Constants.Defaults.noSleepDefaultDuration
        static let noSleepActivateOnStart = Constants.Defaults.noSleepActivateOnStart
        static let noSleepDeactivateOnSleep = Constants.Defaults.noSleepDeactivateOnSleep
        static let noSleepSimulateActivity = Constants.Defaults.noSleepSimulateActivity
        static let activityCheckInterval = Constants.Defaults.activityCheckInterval
        static let activityIdleMultiplier = Constants.Defaults.activityIdleMultiplier
        static let badgePollInterval = Constants.Defaults.badgePollInterval
        static let badgeIconSize = Constants.Defaults.badgeIconSize
        static let timeFormat = Constants.Defaults.timeFormat
        static let calendarProvider = Constants.Defaults.calendarProvider
        static let featureCalendar = Constants.Defaults.featureCalendar
        static let featureNoSleep = Constants.Defaults.featureNoSleep
        static let featureNotifications = Constants.Defaults.featureNotifications
        static let featureBadges = Constants.Defaults.featureBadges
        // Logging configuration
        static let loggingEnabled = Constants.Defaults.loggingEnabled
        static let fileLoggingEnabled = Constants.Defaults.fileLoggingEnabled
        static let logLevelRaw = Constants.Defaults.logLevelRaw
    }

extension UserDefaults {
    func registerDefaults() {
        register(defaults: [
            DefaultsKeys.meetingTitleMaxLength: Constants.DefaultValues.meetingTitleMaxLength,
            DefaultsKeys.showTomorrowEvents: true,
            DefaultsKeys.showDeclinedEvents: false,
            DefaultsKeys.notificationMinutesBefore: Constants.DefaultValues.notificationMinutesBefore,
            DefaultsKeys.endOfEventNotification: false,
            DefaultsKeys.hideIconWhenNotRunning: false,
            DefaultsKeys.hideIconWhenNoNotification: false,
            DefaultsKeys.grayscaleWhenNoNotifications: true,
            "SUEnableAutomaticChecks": false,
            DefaultsKeys.noSleepSleepMode: SleepMode.systemOnly.rawValue,
            DefaultsKeys.noSleepDefaultDuration: Constants.DefaultValues.noSleepDefaultDuration,
            DefaultsKeys.noSleepActivateOnStart: false,
            DefaultsKeys.noSleepDeactivateOnSleep: true,
            DefaultsKeys.noSleepSimulateActivity: false,
            DefaultsKeys.activityCheckInterval: Constants.DefaultValues.activityCheckInterval,
            DefaultsKeys.activityIdleMultiplier: Constants.DefaultValues.activityIdleMultiplier,
            DefaultsKeys.badgePollInterval: Constants.DefaultValues.badgePollInterval,
            DefaultsKeys.badgeIconSize: "medium",
            DefaultsKeys.timeFormat: "relative",
            DefaultsKeys.calendarProvider: CalendarProvider.eventKit.rawValue,
            DefaultsKeys.featureCalendar: true,
            DefaultsKeys.featureNoSleep: true,
            DefaultsKeys.featureNotifications: true,
            DefaultsKeys.featureBadges: true,
            // Logging configuration — warning level by default for power efficiency
            DefaultsKeys.loggingEnabled: true,
            DefaultsKeys.fileLoggingEnabled: true,
            DefaultsKeys.logLevelRaw: Constants.DefaultValues.logLevelRaw
        ])
    }
}
