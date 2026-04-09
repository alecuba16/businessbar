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

final class BadgeMonitor {
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

    init() {
        setupDockElement()
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
    private func allDockItemElements() -> [AXUIElement] {
        guard let dockElement else {
            Self.logger.warning("allDockItemElements — dockElement is nil (Dock not set up)")
            return []
        }

        var topRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &topRef) == .success,
              let topChildren = topRef as? [AXUIElement] else {
            Self.logger.warning("allDockItemElements — failed to read Dock children (AX permission revoked?)")
            return []
        }

        var items: [AXUIElement] = []
        for child in topChildren {
            if getBundleIdentifier(from: child) != nil {
                items.append(child)
            } else {
                var nestedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &nestedRef) == .success,
                   let grandchildren = nestedRef as? [AXUIElement] {
                    items.append(contentsOf: grandchildren)
                }
            }
        }
        let bundleIDs = items.compactMap { getBundleIdentifier(from: $0) }
        Self.logger.debug("allDockItemElements — \(topChildren.count) top-level child(ren), \(items.count) dock item(s) found, bundle IDs: \(bundleIDs)")
        return items
    }

    // MARK: - Dock element setup

    private func setupDockElement() {
        guard let dockApp = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            Self.logger.warning("setupDockElement — Dock process not found")
            return
        }
        dockPID = dockApp.processIdentifier
        dockElement = AXUIElementCreateApplication(dockPID)
        Self.logger.info("setupDockElement — Dock PID: \(self.dockPID)")
    }

    func restartPollTimer() {
        guard pollTimer != nil else { return }
        startPollTimer()
    }

    // MARK: - Poll timer

    private var currentPollInterval: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: Constants.Defaults.badgePollInterval)
        return TimeInterval(stored > 0 ? stored : Constants.DefaultValues.badgePollInterval)
    }

    private func startPollTimer() {
        stopPollTimer()
        let interval = currentPollInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollBadges()
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollBadges() {
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
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXBundleIdentifier" as CFString, &valueRef) == .success,
           let bundleID = valueRef as? String, !bundleID.isEmpty {
            return bundleID
        }

        // Approach 2: AXURL → Bundle.bundleIdentifier — macOS 14+ Dock items
        // expose the app bundle as a file URL instead of a bare bundle-ID string.
        var urlRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlRef) == .success,
           let nsURL = urlRef as? NSURL {
            return Bundle(url: nsURL as URL)?.bundleIdentifier
        }

        return nil
    }

    private func getBadgeValue(from element: AXUIElement) -> Int {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &valueRef) == .success,
              let badgeText = valueRef as? String else {
            return 0
        }
        let digits = badgeText.prefix(while: { $0.isNumber })
        return Int(digits) ?? (badgeText.isEmpty ? 0 : 1)
    }

    // MARK: - Permission

    private func checkAccessibilityPermission() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
