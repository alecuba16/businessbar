import AppKit
import BusinessBarCore

enum MenuBuilder {
    @MainActor
    static func build(
        events: [CalendarEvent],
        nextEvent: CalendarEvent?,
        isLoading: Bool,
        noSleepManager: NoSleepManager,
        onJoinMeeting: @escaping (CalendarEvent) -> Void,
        onDismissEvent: @escaping (String) -> Void,
        onToggleNoSleep: @escaping () -> Void,
        onActivateNoSleep: @escaping (TimeInterval?) -> Void,
        onDeactivateNoSleep: @escaping () -> Void,
        onShowPreferences: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        showEvents: Bool,
        showNoSleep: Bool
    ) -> NSMenu {
        let menu = NSMenu()
        
        if showEvents {
            if isLoading {
                let loadingItem = NSMenuItem(title: "Loading events...", action: nil, keyEquivalent: "")
                loadingItem.isEnabled = false
                menu.addItem(loadingItem)
            } else {
                addEventSection(to: menu, events: events, onJoinMeeting: onJoinMeeting, onDismissEvent: onDismissEvent)
            }
        } else {
            let disabledItem = NSMenuItem(title: "Calendar integration disabled", action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            menu.addItem(disabledItem)
        }

        menu.addItem(NSMenuItem.separator())

        if showEvents, let nextEvent = nextEvent, nextEvent.meetingLink != nil {
            let joinItem = NSMenuItem(title: "Join Next Meeting", action: #selector(MenuActionHandler.joinNextMeeting), keyEquivalent: "j")
            joinItem.representedObject = MenuAction.joinNextMeeting(nextEvent, onJoinMeeting)
            joinItem.target = MenuActionHandler.shared
            menu.addItem(joinItem)
        }

        let createItem = NSMenuItem(title: "Create Meeting...", action: nil, keyEquivalent: "")
        createItem.isEnabled = false
        menu.addItem(createItem)

        menu.addItem(NSMenuItem.separator())

        if showNoSleep {
            addNoSleepSection(to: menu, noSleepManager: noSleepManager, onToggleNoSleep: onToggleNoSleep, onActivateNoSleep: onActivateNoSleep, onDeactivateNoSleep: onDeactivateNoSleep)
        } else {
            let disabledItem = NSMenuItem(title: "NoSleep disabled", action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            menu.addItem(disabledItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(MenuActionHandler.showPreferences), keyEquivalent: ",")
        prefsItem.representedObject = MenuAction.showPreferences(onShowPreferences)
        prefsItem.target = MenuActionHandler.shared
        menu.addItem(prefsItem)
        
        let quitItem = NSMenuItem(title: "Quit BusinessBar", action: #selector(MenuActionHandler.quit), keyEquivalent: "q")
        quitItem.representedObject = MenuAction.quit(onQuit)
        quitItem.target = MenuActionHandler.shared
        menu.addItem(quitItem)
        
        return menu
    }
    
    @MainActor
    private static func addEventSection(to menu: NSMenu, events: [CalendarEvent], onJoinMeeting: @escaping (CalendarEvent) -> Void, onDismissEvent: @escaping (String) -> Void) {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        
        let todayEvents = events.filter { $0.startDate >= startOfToday && $0.startDate < startOfTomorrow }
        let tomorrowEvents = events.filter { $0.startDate >= startOfTomorrow }
        
        if !todayEvents.isEmpty {
            let todayHeader = NSMenuItem(title: "— Today —", action: nil, keyEquivalent: "")
            todayHeader.isEnabled = false
            menu.addItem(todayHeader)
            
            for event in todayEvents {
                addEventItem(to: menu, event: event, onJoinMeeting: onJoinMeeting, onDismissEvent: onDismissEvent)
            }
        }
        
        let showTomorrow = UserDefaults.standard.bool(forKey: Constants.Defaults.showTomorrowEvents)
        if showTomorrow && !tomorrowEvents.isEmpty {
            menu.addItem(NSMenuItem.separator())
            
            let tomorrowHeader = NSMenuItem(title: "— Tomorrow —", action: nil, keyEquivalent: "")
            tomorrowHeader.isEnabled = false
            menu.addItem(tomorrowHeader)
            
            for event in tomorrowEvents {
                addEventItem(to: menu, event: event, onJoinMeeting: onJoinMeeting, onDismissEvent: onDismissEvent)
            }
        }
        
        if todayEvents.isEmpty && (tomorrowEvents.isEmpty || !showTomorrow) {
            let noEventsItem = NSMenuItem(title: "No upcoming events", action: nil, keyEquivalent: "")
            noEventsItem.isEnabled = false
            menu.addItem(noEventsItem)
        }
    }
    
    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    @MainActor
    private static func addEventItem(to menu: NSMenu, event: CalendarEvent, onJoinMeeting: @escaping (CalendarEvent) -> Void, onDismissEvent: @escaping (String) -> Void) {
        let startTime = eventTimeFormatter.string(from: event.startDate)
        let endTime = eventTimeFormatter.string(from: event.endDate)
        
        let prefix = event.isHappening ? "● " : "○ "
        let title = "\(prefix)\(startTime)-\(endTime)  \(event.title)"
        
        let eventItem = NSMenuItem(title: title, action: #selector(MenuActionHandler.eventClicked), keyEquivalent: "")
        eventItem.representedObject = MenuAction.eventClicked(event, onJoinMeeting, onDismissEvent)
        eventItem.target = MenuActionHandler.shared
        
        if event.meetingLink != nil {
            eventItem.submenu = createEventSubmenu(for: event, onJoinMeeting: onJoinMeeting, onDismissEvent: onDismissEvent)
        }
        
        menu.addItem(eventItem)
    }
    
    @MainActor
    private static func createEventSubmenu(for event: CalendarEvent, onJoinMeeting: @escaping (CalendarEvent) -> Void, onDismissEvent: @escaping (String) -> Void) -> NSMenu {
        let submenu = NSMenu()
        
        if event.meetingLink != nil {
            let joinItem = NSMenuItem(title: "Join Meeting", action: #selector(MenuActionHandler.joinMeeting), keyEquivalent: "")
            joinItem.representedObject = MenuAction.joinMeeting(event, onJoinMeeting)
            joinItem.target = MenuActionHandler.shared
            submenu.addItem(joinItem)
        }
        
        let dismissItem = NSMenuItem(title: "Dismiss", action: #selector(MenuActionHandler.dismissEvent), keyEquivalent: "")
        dismissItem.representedObject = MenuAction.dismissEvent(event.id, onDismissEvent)
        dismissItem.target = MenuActionHandler.shared
        submenu.addItem(dismissItem)
        
        return submenu
    }
    
    @MainActor
    private static func addNoSleepSection(to menu: NSMenu, noSleepManager: NoSleepManager, onToggleNoSleep: @escaping () -> Void, onActivateNoSleep: @escaping (TimeInterval?) -> Void, onDeactivateNoSleep: @escaping () -> Void) {
        let header = NSMenuItem(title: "— NoSleep —", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        if noSleepManager.isActive {
            let statusText: String
            if noSleepManager.timeRemaining.isInfinite {
                statusText = "☕️ Active"
            } else {
                let hours = Int(noSleepManager.timeRemaining) / 3600
                let minutes = (Int(noSleepManager.timeRemaining) % 3600) / 60
                
                if hours > 0 {
                    statusText = "☕️ Active — \(hours)h \(minutes)m remaining"
                } else {
                    statusText = "☕️ Active — \(minutes)m remaining"
                }
            }
            
            let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            
            let deactivateItem = NSMenuItem(title: "Deactivate", action: #selector(MenuActionHandler.deactivateNoSleep), keyEquivalent: "")
            deactivateItem.representedObject = MenuAction.deactivateNoSleep(onDeactivateNoSleep)
            deactivateItem.target = MenuActionHandler.shared
            menu.addItem(deactivateItem)
        } else {
            let activateItem = NSMenuItem(title: "Activate", action: #selector(MenuActionHandler.toggleNoSleep), keyEquivalent: "")
            activateItem.representedObject = MenuAction.toggleNoSleep(onToggleNoSleep)
            activateItem.target = MenuActionHandler.shared
            menu.addItem(activateItem)
        }
        
        let activateForItem = NSMenuItem(title: "Activate for...", action: nil, keyEquivalent: "")
        activateForItem.submenu = createNoSleepDurationMenu(onActivateNoSleep: onActivateNoSleep)
        menu.addItem(activateForItem)
    }
    
    @MainActor
    private static func createNoSleepDurationMenu(onActivateNoSleep: @escaping (TimeInterval?) -> Void) -> NSMenu {
        let submenu = NSMenu()

        for option in noSleepDurationOptions() {
            let title = option.title + (option.duration.flatMap(approximateEndTimeSuffix) ?? "")
            let item = NSMenuItem(title: title, action: #selector(MenuActionHandler.activateNoSleepFor), keyEquivalent: "")
            item.representedObject = MenuAction.activateNoSleepFor(option.duration, onActivateNoSleep)
            item.target = MenuActionHandler.shared
            submenu.addItem(item)
        }

        return submenu
    }

    private static func noSleepDurationOptions() -> [(title: String, duration: TimeInterval?)] {
        var options: [(String, TimeInterval?)] = [
            ("Indefinitely", nil),
            ("15 minutes", 15 * 60),
            ("30 minutes", 30 * 60)
        ]

        for hour in 1...8 {
            let label = "\(hour) hour\(hour == 1 ? "" : "s")"
            options.append((label, TimeInterval(hour * 60 * 60)))
        }

        options.append(("12 hours", 12 * 60 * 60))
        options.append(("16 hours", 16 * 60 * 60))

        return options
    }

    private static func approximateEndTimeSuffix(for duration: TimeInterval) -> String? {
        guard duration > 0 else { return nil }
        let endDate = Date().addingTimeInterval(duration)
        return " (ends ~\(durationFormatter.string(from: endDate)))"
    }

    private static var durationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

enum MenuAction {
    case joinNextMeeting(CalendarEvent, (CalendarEvent) -> Void)
    case joinMeeting(CalendarEvent, (CalendarEvent) -> Void)
    case eventClicked(CalendarEvent, (CalendarEvent) -> Void, (String) -> Void)
    case dismissEvent(String, (String) -> Void)
    case toggleNoSleep(() -> Void)
    case activateNoSleepFor(TimeInterval?, (TimeInterval?) -> Void)
    case deactivateNoSleep(() -> Void)
    case showPreferences(() -> Void)
    case quit(() -> Void)
}

@MainActor
final class MenuActionHandler: NSObject {
    static let shared = MenuActionHandler()
    
    @objc func joinNextMeeting(_ sender: NSMenuItem) {
        guard case .joinNextMeeting(let event, let handler) = sender.representedObject as? MenuAction else { return }
        handler(event)
    }
    
    @objc func joinMeeting(_ sender: NSMenuItem) {
        guard case .joinMeeting(let event, let handler) = sender.representedObject as? MenuAction else { return }
        handler(event)
    }
    
    @objc func eventClicked(_ sender: NSMenuItem) {
        guard case .eventClicked(let event, let joinHandler, _) = sender.representedObject as? MenuAction else { return }
        if event.meetingLink != nil {
            joinHandler(event)
        }
    }
    
    @objc func dismissEvent(_ sender: NSMenuItem) {
        guard case .dismissEvent(let eventID, let handler) = sender.representedObject as? MenuAction else { return }
        handler(eventID)
    }
    
    @objc func toggleNoSleep(_ sender: NSMenuItem) {
        guard case .toggleNoSleep(let handler) = sender.representedObject as? MenuAction else { return }
        handler()
    }
    
    @objc func activateNoSleepFor(_ sender: NSMenuItem) {
        guard case .activateNoSleepFor(let duration, let handler) = sender.representedObject as? MenuAction else { return }
        handler(duration)
    }
    
    @objc func deactivateNoSleep(_ sender: NSMenuItem) {
        guard case .deactivateNoSleep(let handler) = sender.representedObject as? MenuAction else { return }
        handler()
    }
    
    @objc func showPreferences(_ sender: NSMenuItem) {
        guard case .showPreferences(let handler) = sender.representedObject as? MenuAction else { return }
        handler()
    }
    
    @objc func quit(_ sender: NSMenuItem) {
        guard case .quit(let handler) = sender.representedObject as? MenuAction else { return }
        handler()
    }
}
