import ApplicationServices
import AppKit
import Foundation
import os.log

// MARK: - BadgeMonitor
// Reads dock-icon badge labels via the Accessibility API.
// Uses a 1-second polling timer AND an AXObserver that fires when Dock child
// elements are created or destroyed (app launches / quits), keeping element
// references fresh without needing a restart.
//
// Internal — only BadgeManager should create and drive this type.

final class BadgeMonitor: BadgeMonitoring {
    // MARK: - Internal

    var onBadgeUpdate: ((String, Int) -> Void)?

    private static let logger = Logger(subsystem: "com.businessbar.app", category: "BadgeMonitor")

    // MARK: - Private state

    private var pollTimer: Timer?
    private var dockPID: pid_t = 0
    private var dockElement: AXUIElement?
    private var appElements: [String: AXUIElement] = [:]

    // AXObserver for app launch / quit in the Dock
    private var axObserver: AXObserver?

    /// Last badge value reported per app — used to suppress duplicate poll logs.
    private var lastLoggedBadges: [String: Int] = [:]

    // MARK: - Lifecycle

    private let defaults: UserDefaults
    private let trust: () -> Bool
    private let attribute: (AXUIElement, String) -> CFTypeRef?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Timer
    private let observe: ((pid_t, AXUIElement, @escaping () -> Void) -> (() -> Void))?
    private var cancelObserver: (() -> Void)?

    init(defaults: UserDefaults = .standard,
         trust: @escaping () -> Bool = { AXIsProcessTrusted() },
         dock: () -> (pid_t, AXUIElement?) = {
             guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return (0, nil) }
             return (app.processIdentifier, AXUIElementCreateApplication(app.processIdentifier))
         },
         attribute: @escaping (AXUIElement, String) -> CFTypeRef? = { element, name in
             var value: CFTypeRef?
             guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
             return value
         },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Timer = { interval, action in
             Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() }
         },
         observe: ((pid_t, AXUIElement, @escaping () -> Void) -> (() -> Void))? = nil) {
        self.defaults = defaults
        self.trust = trust
        self.attribute = attribute
        self.schedule = schedule
        self.observe = observe
        (dockPID, dockElement) = dock()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - API

    func startMonitoring(apps: [MonitoredApp]) {
        guard checkAccessibilityPermission() else {
            Self.logger.warning("startMonitoring — blocked: accessibility permission not granted")
            return
        }
        Self.logger.info("startMonitoring — \(apps.count) app(s): \(apps.map { $0.bundleIdentifier })")
        updateAppElements(for: apps)
        startPollTimer()
        setupAXObserver()
    }

    func stopMonitoring() {
        Self.logger.info("stopMonitoring")
        stopPollTimer()
        tearDownAXObserver()
        appElements.removeAll()
        lastLoggedBadges.removeAll()
    }

    func updateAppElements(for apps: [MonitoredApp]) {
        appElements.removeAll()
        let allItems = allDockItemElements()
        for element in allItems {
            if let bundleID = getBundleIdentifier(from: element),
               apps.contains(where: { $0.bundleIdentifier == bundleID }) {
                appElements[bundleID] = element
            }
        }
        let missed = apps.filter { self.appElements[$0.bundleIdentifier] == nil }.map { $0.bundleIdentifier }
        Self.logger.debug("updateAppElements — \(allItems.count) Dock item(s) scanned, \(self.appElements.count)/\(apps.count) app(s) matched: \(Array(self.appElements.keys))")
        if !missed.isEmpty {
            Self.logger.warning("updateAppElements — not found in Dock: \(missed)")
        }
    }

    /// Returns every AXUIElement in the Dock that represents an individual app icon.
    ///
    /// On macOS 14+ the Dock accessibility tree is two levels deep:
    ///   Application (Dock) → AXList/AXGroup → AXDockItem
    ///
    /// On older versions the items may be direct children of the Application element.
    /// We handle both by checking for a bundle identifier at each level and descending
    /// one level further when the immediate child is a container (no bundle ID).
    func allDockItemElements() -> [AXUIElement] {
        guard let dockElement else {
            Self.logger.warning("allDockItemElements — dockElement is nil (Dock not set up)")
            return []
        }

        guard let topChildren = attribute(dockElement, kAXChildrenAttribute) as? [AXUIElement] else {
            Self.logger.warning("allDockItemElements — failed to read Dock children (AX permission revoked?)")
            return []
        }

        var items: [AXUIElement] = []
        for child in topChildren {
            if getBundleIdentifier(from: child) != nil {
                items.append(child)
            } else {
                if let grandchildren = attribute(child, kAXChildrenAttribute) as? [AXUIElement] {
                    items.append(contentsOf: grandchildren)
                }
            }
        }
        let bundleIDs = items.compactMap { getBundleIdentifier(from: $0) }
        Self.logger.debug("allDockItemElements — \(topChildren.count) top-level child(ren), \(items.count) dock item(s) found, bundle IDs: \(bundleIDs)")
        return items
    }

    // MARK: - Dock element setup


    func restartPollTimer() {
        guard pollTimer != nil else { return }
        startPollTimer()
    }

    // MARK: - Poll timer

    private var currentPollInterval: TimeInterval {
        let stored = defaults.integer(forKey: Constants.Defaults.badgePollInterval)
        return TimeInterval(stored > 0 ? stored : Constants.DefaultValues.badgePollInterval)
    }

    private func startPollTimer() {
        stopPollTimer()
        let interval = currentPollInterval
        pollTimer = schedule(interval) { [weak self] in
            self?.pollBadges()
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func pollBadges() {
        for (bundleID, element) in appElements {
            let badge = getBadgeValue(from: element)
            let previous = lastLoggedBadges[bundleID] ?? 0
            guard badge != previous else { continue }
            Self.logger.debug("poll — \(bundleID): \(previous) → \(badge)")
            lastLoggedBadges[bundleID] = badge
            onBadgeUpdate?(bundleID, badge)
        }
    }

    // MARK: - AXObserver (app launch / quit detection)

    private func setupAXObserver() {
        if let observe, let dockElement {
            cancelObserver?()
            cancelObserver = observe(dockPID, dockElement) { [weak self] in self?.refreshDockChildren() }
            return
        }
        guard dockPID != 0 else {
            Self.logger.warning("setupAXObserver — skipped (dockPID is 0)")
            return
        }
        tearDownAXObserver()

        var observer: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let result = AXObserverCreate(dockPID, { _, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<BadgeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleDockChildChange(element: element, notification: notification as String)
        }, &observer)

        guard result == .success, let observer else {
            Self.logger.error("setupAXObserver — AXObserverCreate failed (error \(result.rawValue))")
            return
        }

        axObserver = observer

        AXObserverAddNotification(observer, dockElement!, kAXCreatedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, dockElement!, kAXUIElementDestroyedNotification as CFString, selfPtr)

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        Self.logger.info("setupAXObserver — watching kAXCreated + kAXUIElementDestroyed on Dock")
    }

    private func tearDownAXObserver() {
        cancelObserver?()
        cancelObserver = nil
        guard let observer = axObserver, let dockElement else {
            axObserver = nil
            return
        }
        AXObserverRemoveNotification(observer, dockElement, kAXCreatedNotification as CFString)
        AXObserverRemoveNotification(observer, dockElement, kAXUIElementDestroyedNotification as CFString)
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        axObserver = nil
    }

    private func handleDockChildChange(element: AXUIElement, notification: String) {
        Self.logger.debug("handleDockChildChange — notification: \(notification)")
        refreshDockChildren()
    }

    func refreshDockChildren() {
        let currentBundleIDs = Set(appElements.keys)
        var freshElements: [String: AXUIElement] = [:]

        for item in allDockItemElements() {
            guard let bundleID = getBundleIdentifier(from: item) else { continue }
            if currentBundleIDs.contains(bundleID) {
                freshElements[bundleID] = item
            }
        }

        appElements = freshElements
        Self.logger.debug("handleDockChildChange — refreshed \(freshElements.count) element(s): \(Array(freshElements.keys))")
    }

    // MARK: - AX attribute helpers

    private func getBundleIdentifier(from element: AXUIElement) -> String? {
        // Approach 1: AXBundleIdentifier — present on some older macOS versions.
        if let bundleID = attribute(element, "AXBundleIdentifier") as? String, !bundleID.isEmpty {
            return bundleID
        }

        // Approach 2: AXURL → Bundle.bundleIdentifier — macOS 14+ Dock items
        // expose the app bundle as a file URL instead of a bare bundle-ID string.
        if let nsURL = attribute(element, "AXURL") as? NSURL {
            return Bundle(url: nsURL as URL)?.bundleIdentifier
        }

        return nil
    }

    private func getBadgeValue(from element: AXUIElement) -> Int {
        return Self.parseBadge(attribute(element, "AXStatusLabel") as? String)
    }

    static func parseBadge(_ text: String?) -> Int {
        guard let badgeText = text else { return 0 }
        let digits = badgeText.prefix(while: { $0.isNumber })
        return Int(digits) ?? (badgeText.isEmpty ? 0 : 1)
    }

    // MARK: - Permission

    private func checkAccessibilityPermission() -> Bool {
        trust()
    }

    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
