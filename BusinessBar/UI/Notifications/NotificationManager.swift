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
        /// Whether the new-event confirmation feature is enabled.
        var isNewEventsEnabled: () -> Bool
        /// Whether the pending-invite confirmation feature is enabled.
        var isPendingInvitesEnabled: () -> Bool

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
                openURL: { NSWorkspace.shared.open($0) },
                isNewEventsEnabled: {
                    (UserDefaults.standard.object(forKey: Constants.Defaults.notifyNewEvents) as? Bool) ?? false
                },
                isPendingInvitesEnabled: {
                    (UserDefaults.standard.object(forKey: Constants.Defaults.notifyPendingInvites) as? Bool) ?? false
                }
            )
        }
    }

    private let dependencies: Dependencies

    /// Coverage access to the injected boundaries: scenarios assert on the
    /// live flag readers and the request recording closures.
    var dependenciesForCoverage: Dependencies { dependencies }
    /// Injected after init by AppDelegate: closures the notification action
    /// path calls. Kept mutable here because Dependencies is a value copy.
    private var rsvpHandler: (@MainActor (String, String, CalendarEvent.RSVPStatus) -> Void)?
    private var deliveredInviteIDsReader: () -> Set<String> = { [] }
    private var markInviteDelivered: (String) -> Void = { _ in }
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
        
        let acceptAction = UNNotificationAction(
            identifier: "RSVP_ACCEPT",
            title: "Yes",
            options: [.authenticationRequired]
        )
        let declineAction = UNNotificationAction(
            identifier: "RSVP_DECLINE",
            title: "No",
            options: [.authenticationRequired]
        )
        let tentativeAction = UNNotificationAction(
            identifier: "RSVP_TENTATIVE",
            title: "Maybe",
            options: [.authenticationRequired]
        )
        let inviteCategory = UNNotificationCategory(
            identifier: "EVENT_INVITE",
            actions: [acceptAction, declineAction, tentativeAction],
            intentIdentifiers: [],
            options: []
        )
        
        let keepAction = UNNotificationAction(
            identifier: "NEW_EVENT_KEEP",
            title: "OK",
            options: []
        )
        // One action only: the notification needs no decision from the
        // user, a second button doing the same thing would be noise.
        let newEventCategory = UNNotificationCategory(
            identifier: "NEW_EVENT",
            actions: [keepAction],
            intentIdentifiers: [],
            options: []
        )
        
        dependencies.configure(self, [eventCategory, inviteCategory, newEventCategory])
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

        // New auto-added events: one notification per first-seen event.
        dependencies.notificationCenter
            .publisher(for: .businessBarNewEventsAppeared)
            .sink { [weak self] notification in
                guard let self,
                      let events = notification.userInfo?["events"] as? [CalendarEvent] else { return }
                Task { @MainActor in
                    for event in events {
                        self.presentNewEventNotification(for: event)
                    }
                }
            }
            .store(in: &cancellables)

        // Unanswered invitations: shown until answered. macOS may drop the
        // banner under its own rules (banner style, Do Not Disturb), so each
        // refresh re-adds invites that have no delivered notification yet.
        dependencies.notificationCenter
            .publisher(for: .businessBarPendingRSVPsAppeared)
            .sink { [weak self] notification in
                guard let self,
                      let events = notification.userInfo?["events"] as? [CalendarEvent] else { return }
                Task { @MainActor in
                    for event in events {
                        self.presentInviteNotification(for: event)
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

    // MARK: - RSVP plumbing

    /// AppDelegate injects the RSVP action target (the live MeetingManager).
    func setRSVPHandler(_ handler: (@MainActor (String, String, CalendarEvent.RSVPStatus) -> Void)?) {
        rsvpHandler = handler
    }

    /// AppDelegate owns delivered-invite bookkeeping because it survives
    /// notification removal by the system.
    func setDeliveredInviteBookkeeping(
        delivered: @escaping () -> Set<String>,
        mark: @escaping (String) -> Void
    ) {
        deliveredInviteIDsReader = delivered
        markInviteDelivered = mark
    }

    /// Removes a delivered invite notification after it was answered.
    func cancelInviteNotification(for eventID: String) {
        guard dependencies.isAvailable() else { return }
        dependencies.remove(["invite-\(eventID)"])
    }

    /// Surfaces a failed RSVP answer from a notification action: by now the
    /// invite banner is gone, so without this the user would never learn the
    /// answer was not sent.
    func notifyRSVPFailure(for eventID: String) {
        guard dependencies.isAvailable(), areNotificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Invitation"
        content.body = "Could not send the answer. Open the menu to try again from the invitations panel."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "rsvp-failed-\(eventID)",
            content: content,
            trigger: nil
        )
        dependencies.add(request)
    }

    // MARK: - Confirmation notifications

    private func presentNewEventNotification(for event: CalendarEvent) {
        guard dependencies.isAvailable(),
              areNotificationsEnabled,
              dependencies.isNewEventsEnabled() else { return }

        let content = UNMutableNotificationContent()
        content.title = "New Event Added"
        content.body = "\(event.title) · \(Self.timeLine(for: event))"
        content.sound = .default
        content.categoryIdentifier = "NEW_EVENT"
        content.userInfo = ["eventID": event.id]

        let request = UNNotificationRequest(
            identifier: "new-event-\(event.id)",
            content: content,
            trigger: nil
        )
        dependencies.add(request)
    }

    private func presentInviteNotification(for event: CalendarEvent) {
        guard dependencies.isAvailable(),
              areNotificationsEnabled,
              dependencies.isPendingInvitesEnabled() else { return }
        guard !deliveredInviteIDsReader().contains(event.id) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Invitation"
        let organizer = event.organizer.map { " from \($0)" } ?? ""
        content.body = "\(event.title)\(organizer) · \(Self.timeLine(for: event))"
        content.sound = .default
        content.categoryIdentifier = "EVENT_INVITE"
        content.userInfo = [
            "eventID": event.id,
            "calendarID": event.calendar.id
        ]

        let request = UNNotificationRequest(
            identifier: "invite-\(event.id)",
            content: content,
            trigger: nil
        )
        dependencies.add(request)
        markInviteDelivered(event.id)
    }

    private static func timeLine(for event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(formatter.string(from: event.startDate))"
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        Task { @MainActor in
            self.dispatchAction(action, userInfo: userInfo)
        }
        completionHandler()
    }

    /// Extracts the action payload fields and forwards them. The delegate
    /// method above only forwards system-built response objects, so this is
    /// the entry point scenarios can drive with a plain userInfo dict.
    @MainActor
    func dispatchAction(_ action: String, userInfo: [AnyHashable: Any]) {
        let meetingLink = userInfo["meetingLink"] as? String
        let eventID = userInfo["eventID"] as? String
        let calendarID = userInfo["calendarID"] as? String
        handleAction(action, meetingLink: meetingLink, eventID: eventID, calendarID: calendarID)
    }

    func handleAction(_ action: String, meetingLink: String?, eventID: String?, calendarID: String? = nil) {
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
            
        case "RSVP_ACCEPT":
            if let eventID, let calendarID {
                rsvpHandler?(eventID, calendarID, .accepted)
            }
            logIfRSVPHandlerMissing(eventID: eventID, calendarID: calendarID)
            
        case "RSVP_DECLINE":
            if let eventID, let calendarID {
                rsvpHandler?(eventID, calendarID, .declined)
            }
            logIfRSVPHandlerMissing(eventID: eventID, calendarID: calendarID)
            
        case "RSVP_TENTATIVE":
            if let eventID, let calendarID {
                rsvpHandler?(eventID, calendarID, .tentative)
            }
            logIfRSVPHandlerMissing(eventID: eventID, calendarID: calendarID)
            
        case "DISMISS_ACTION", "NEW_EVENT_KEEP":
            break
            
        default:
            break
        }
        
    }

    /// Fires when an RSVP action button arrives but no handler was injected
    /// yet. Without the log the answer would silently vanish.
    private func logIfRSVPHandlerMissing(eventID: String?, calendarID: String?) {
        if rsvpHandler == nil, let eventID, let calendarID {
            AppLogger.error("RSVP action for event \(eventID) dropped: no handler installed", category: "Notifications")
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
