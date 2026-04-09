import AppKit
import BusinessBarCore
import Combine
import Foundation

import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    // UNUserNotificationCenter.current() requires a valid bundle proxy (i.e. the
    // process must be running inside a .app bundle). Accessing it as a lazy stored
    // property means the call only happens on first use, after the bundle is fully
    // registered — it never fires at stored-property initialisation time.
    private lazy var center: UNUserNotificationCenter = UNUserNotificationCenter.current()
    private var cancellables = Set<AnyCancellable>()

    private var areNotificationsEnabled: Bool {
        Self.notificationsEnabled()
    }
    nonisolated private static func notificationsEnabled() -> Bool {
        if let value = UserDefaults.standard.object(forKey: Constants.Defaults.featureNotifications) as? Bool {
            return value
        }
        return true
    }

    override init() {
        super.init()
        // Only wire up the delegate / categories when a real bundle is present.
        // Running as a raw SPM binary (.build/…/BusinessBar) has no bundle proxy
        // and will crash inside UNUserNotificationCenter.current() otherwise.
        guard Bundle.main.bundleIdentifier != nil else {
            AppLogger.warning("No bundle identifier — skipping notification setup (running outside .app bundle?)", category: "Notifications")
            return
        }
        AppLogger.info("Initializing NotificationManager", category: "Notifications")
        center.delegate = self
        setupCategories()
        setupPreferenceObserver()
    }
    
    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else {
            AppLogger.warning("Cannot request notification authorization — no bundle identifier", category: "Notifications")
            return
        }
        guard areNotificationsEnabled else {
            AppLogger.info("Notification feature disabled — skipping authorization request", category: "Notifications")
            return
        }
        AppLogger.info("Requesting notification authorization", category: "Notifications")
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                AppLogger.error("Notification authorization error: \(error.localizedDescription)", category: "Notifications")
            } else if granted {
                AppLogger.info("Notification authorization granted", category: "Notifications")
            } else {
                AppLogger.warning("Notification authorization denied by user", category: "Notifications")
            }
        }
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
        
        center.setNotificationCategories([eventCategory])
    }

    private func setupPreferenceObserver() {
        NotificationCenter.default
            .publisher(for: .businessBarPreferencesDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if !Self.notificationsEnabled() {
                        self.center.removeAllPendingNotificationRequests()
                        self.center.removeAllDeliveredNotifications()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func scheduleNotification(for event: CalendarEvent, minutesBefore: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
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
        
        guard triggerDate > Date() else { return }
        
        let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "\(event.id)_\(minutesBefore)",
            content: content,
            trigger: trigger
        )
        
        let eventID = event.id  // capture as Sendable String before @Sendable closure
        center.add(request) { error in
            if let error {
                AppLogger.error("Failed to schedule notification for event \(eventID): \(error.localizedDescription)", category: "Notifications")
            }
        }
    }
    
    func cancelNotifications(for eventID: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard areNotificationsEnabled else { return }
        center.removePendingNotificationRequests(withIdentifiers: [eventID])
    }

    func cancelAllNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard Self.notificationsEnabled() else {
            completionHandler()
            return
        }
        let userInfo = response.notification.request.content.userInfo
        
        switch response.actionIdentifier {
        case "JOIN_ACTION":
            if let urlString = userInfo["meetingLink"] as? String,
               let url = URL(string: urlString) {
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                }
            }
            
        case "SNOOZE_5":
            if let eventID = userInfo["eventID"] as? String {
                Task { @MainActor in
                    self.snoozeNotification(eventID: eventID, minutes: 5)
                }
            }
            
        case "SNOOZE_10":
            if let eventID = userInfo["eventID"] as? String {
                Task { @MainActor in
                    self.snoozeNotification(eventID: eventID, minutes: 10)
                }
            }
            
        case "DISMISS_ACTION":
            break
            
        default:
            break
        }
        
        completionHandler()
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
        
        center.add(request)
    }
}
