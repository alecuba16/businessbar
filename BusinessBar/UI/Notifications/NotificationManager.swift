import AppKit
import BusinessBarCore
import Combine
import Foundation

import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    struct Dependencies {
        var isAvailable: () -> Bool
        var isEnabled: () -> Bool
        var now: () -> Date
        var configure: (any UNUserNotificationCenterDelegate, Set<UNNotificationCategory>) -> Void
        var authorize: () -> Void
        var add: (UNNotificationRequest) -> Void
        var remove: ([String]) -> Void
        var removeAll: () -> Void
        var openURL: (URL) -> Void
        var notificationCenter: NotificationCenter = .default

        static var live: Dependencies {
            Dependencies(
                isAvailable: { RuntimeBundle.isPresent },
                isEnabled: { NotificationManager.notificationsEnabled() },
                now: Date.init,
                configure: { delegate, categories in
                    let center = UNUserNotificationCenter.current()
                    center.delegate = delegate
                    center.setNotificationCategories(categories)
                },
                authorize: {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        if let error {
                            AppLogger.error("Notification authorization error: \(error.localizedDescription)", category: "Notifications")
                        } else if granted {
                            AppLogger.info("Notification authorization granted", category: "Notifications")
                        } else {
                            AppLogger.warning("Notification authorization denied by user", category: "Notifications")
                        }
                    }
                },
                add: { request in
                    UNUserNotificationCenter.current().add(request) { error in
                        if let error { AppLogger.error("Failed to schedule notification: \(error.localizedDescription)", category: "Notifications") }
                    }
                },
                remove: { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) },
                removeAll: {
                    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                },
                openURL: { NSWorkspace.shared.open($0) }
            )
        }
    }

    private let dependencies: Dependencies
    private var cancellables = Set<AnyCancellable>()

    private var areNotificationsEnabled: Bool {
        dependencies.isEnabled()
    }
    nonisolated private static func notificationsEnabled() -> Bool {
        if let value = UserDefaults.standard.object(forKey: Constants.Defaults.featureNotifications) as? Bool {
            return value
        }
        return true
    }

    override convenience init() {
        self.init(dependencies: .live)
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        super.init()
        // Only wire up the delegate / categories when a real bundle is present.
        // Running as a raw SPM binary (.build/…/BusinessBar) has no bundle proxy
        // and will crash inside UNUserNotificationCenter.current() otherwise.
        guard dependencies.isAvailable() else {
            AppLogger.warning("No bundle identifier — skipping notification setup (running outside .app bundle?)", category: "Notifications")
            return
        }
        AppLogger.info("Initializing NotificationManager", category: "Notifications")
        setupCategories()
        setupPreferenceObserver()
    }
    
    func requestAuthorization() {
        guard dependencies.isAvailable() else {
            AppLogger.warning("Cannot request notification authorization — no bundle identifier", category: "Notifications")
            return
        }
        guard areNotificationsEnabled else {
            AppLogger.info("Notification feature disabled — skipping authorization request", category: "Notifications")
            return
        }
        AppLogger.info("Requesting notification authorization", category: "Notifications")
        dependencies.authorize()
    }
    
    private func setupCategories() {
        let joinAction = UNNotificationAction(
            identifier: "JOIN_ACTION",
            title: "Join",
            options: .foreground
        )
        
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss",
            options: .destructive
        )
        
        let snooze5Action = UNNotificationAction(
            identifier: "SNOOZE_5",
            title: "Snooze 5 min",
            options: []
        )
        
        let snooze10Action = UNNotificationAction(
            identifier: "SNOOZE_10",
            title: "Snooze 10 min",
            options: []
        )
        
        let eventCategory = UNNotificationCategory(
            identifier: "EVENT_NOTIFICATION",
            actions: [joinAction, snooze5Action, snooze10Action, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        
        dependencies.configure(self, [eventCategory])
    }

    private func setupPreferenceObserver() {
        dependencies.notificationCenter
            .publisher(for: .businessBarPreferencesDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if !self.areNotificationsEnabled {
                        self.dependencies.removeAll()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func scheduleNotification(for event: CalendarEvent, minutesBefore: Int) {
        guard dependencies.isAvailable() else { return }
        guard areNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Upcoming Meeting"
        content.body = event.title
        content.sound = .default
        content.categoryIdentifier = "EVENT_NOTIFICATION"
        content.userInfo = ["eventID": event.id]
        
        if let meetingLink = event.meetingLink {
            content.userInfo["meetingLink"] = meetingLink.absoluteString
        }
        
        let triggerDate = event.startDate.addingTimeInterval(-TimeInterval(minutesBefore * 60))
        
        guard triggerDate > dependencies.now() else { return }
        
        let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "\(event.id)_\(minutesBefore)",
            content: content,
            trigger: trigger
        )
        
        dependencies.add(request)
    }
    
    func cancelNotifications(for eventID: String) {
        guard dependencies.isAvailable() else { return }
        guard areNotificationsEnabled else { return }
        dependencies.remove([eventID])
    }

    func cancelAllNotifications() {
        guard dependencies.isAvailable() else { return }
        dependencies.removeAll()
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let meetingLink = userInfo["meetingLink"] as? String
        let eventID = userInfo["eventID"] as? String
        Task { @MainActor in
            self.handleAction(action, meetingLink: meetingLink, eventID: eventID)
        }
        completionHandler()
    }

    func handleAction(_ action: String, meetingLink: String?, eventID: String?) {
        guard areNotificationsEnabled else { return }
        switch action {
        case "JOIN_ACTION":
            if let urlString = meetingLink,
               let url = URL(string: urlString) {
                dependencies.openURL(url)
            }
            
        case "SNOOZE_5":
            if let eventID {
                snoozeNotification(eventID: eventID, minutes: 5)
            }
            
        case "SNOOZE_10":
            if let eventID {
                snoozeNotification(eventID: eventID, minutes: 10)
            }
            
        case "DISMISS_ACTION":
            break
            
        default:
            break
        }
        
    }
    
    private func snoozeNotification(eventID: String, minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Reminder"
        content.body = "Your meeting is starting soon"
        content.sound = .default
        content.categoryIdentifier = "EVENT_NOTIFICATION"
        content.userInfo = ["eventID": eventID]
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "\(eventID)_snoozed",
            content: content,
            trigger: trigger
        )
        
        dependencies.add(request)
    }
}
