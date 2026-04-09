import AppKit
import BusinessBarCore
import Combine
import KeyboardShortcuts
import os.log
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private var mainStatusItem: NSStatusItem?
    private var badgeStatusItems: [String: NSStatusItem] = [:]

    // MARK: - Toast
    /// Last-seen badge count per app. nil = never seen (no toast on first read).
    private var previousBadgeCounts: [String: Int] = [:]
    /// The currently visible toast popover, if any.
    private var activeToastPopover: NSPopover?
    /// Pending auto-dismiss work item so it can be cancelled on new toasts.
    private var toastDismissTask: DispatchWorkItem?

    /// Refreshes the status bar text every 60 s so relative times stay accurate.
    private var minuteRefreshTimer: Timer?

    // MARK: - Icon caches

    /// Colored calendar icon matching the AppIcon's blue/purple brand color.
    /// Used when no meeting or NoSleep is active — gives the idle status bar
    /// item the same visual identity as the app icon.
    private lazy var cachedAppIcon: NSImage? = Self.renderBrandedIcon()

    /// Template calendar icon for use as a secondary image (not currently
    /// used in the primary status item but kept for future use).
    private lazy var cachedFallbackIcon: NSImage? = {
        if let assetIcon = NSImage(named: "StatusBarIcon") {
            assetIcon.isTemplate = true
            return assetIcon
        }
        return Self.renderFallbackIcon()
    }()
    private var cachedNoSleepInfiniteIcon: NSImage?
    private var cachedNoSleepTimedIcon: NSImage?
    /// Tracks the last-rendered badge image per app to avoid redundant CIFilter work.
    private var renderedBadgeImages: [String: (count: Int, image: NSImage)] = [:]

    private let meetingManager: MeetingManager
    private let badgeManager: BadgeManager
    private let noSleepManager: NoSleepManager
    private let onShowPreferences: () -> Void

    private var cancellables = Set<AnyCancellable>()
    private var isCalendarFeatureEnabled: Bool {
        isFeatureEnabled(Constants.Defaults.featureCalendar)
    }
    private var isNoSleepFeatureEnabled: Bool {
        isFeatureEnabled(Constants.Defaults.featureNoSleep)
    }
    private var isBadgeFeatureEnabled: Bool {
        isFeatureEnabled(Constants.Defaults.featureBadges)
    }
    private enum EventTimeMode: String {
        case relative
        case absolute
    }

    private static let absoluteTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var currentEventTimeMode: EventTimeMode {
        let rawValue = UserDefaults.standard.string(forKey: Constants.Defaults.timeFormat)
        return EventTimeMode(rawValue: rawValue ?? EventTimeMode.relative.rawValue) ?? .relative
    }

    private func isFeatureEnabled(_ key: String) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool {
            return value
        }
        return true
    }

    /// Width of each badge status item is derived from the selected icon size
    /// so the spacing stays consistent with the cropped icon.
    private var badgeIconDimension: CGFloat {
        let setting = UserDefaults.standard.string(forKey: Constants.Defaults.badgeIconSize) ?? "small"
        return setting == "medium" ? 18 : 14
    }

    init(meetingManager: MeetingManager, badgeManager: BadgeManager, noSleepManager: NoSleepManager, onShowPreferences: @escaping () -> Void) {
        self.meetingManager = meetingManager
        self.badgeManager = badgeManager
        self.noSleepManager = noSleepManager
        self.onShowPreferences = onShowPreferences

        super.init()

        setupMainStatusItem()
        setupObservers()
        setupKeyboardShortcuts()
        startMinuteRefreshTimer()
    }

    private func setupMainStatusItem() {
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create a single persistent NSMenu whose contents are rebuilt by
        // NSMenuDelegate.menuWillOpen right before each display. This means the
        // menu always reads fully-committed property values (no @Published willSet
        // timing issues) and never needs to be proactively pushed from observers.
        let menu = NSMenu()
        menu.delegate = self
        mainStatusItem?.menu = menu

        updateMainStatusItem()
    }

    private func setupObservers() {
        // @Published fires in willSet — before the new value is stored on the property.
        // Reading the property inside a sink therefore returns the OLD value.
        // Wrapping in DispatchQueue.main.async defers the read to after willSet
        // completes so we always see the freshly committed value.

        meetingManager.$nextEvent
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateMainStatusItem() }
            }
            .store(in: &cancellables)

        meetingManager.$isLoading
            .filter { !$0 }
            .sink { [weak self] _ in
                // Also refresh the icon when loading finishes — $nextEvent may not
                // fire if nextEvent was already nil before and after the refresh.
                DispatchQueue.main.async { self?.updateMainStatusItem() }
            }
            .store(in: &cancellables)

        noSleepManager.$isActive
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateMainStatusItem() }
            }
            .store(in: &cancellables)

        // Wrap in DispatchQueue.main.async so we read badgeManager's properties
        // AFTER @Published's willSet has committed the new value.
        badgeManager.$badges
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateBadgeStatusItems() }
            }
            .store(in: &cancellables)

        // Adding or removing a monitored app must also refresh the status items —
        // the badges dict won't fire when only the app list changes.
        badgeManager.$monitoredApps
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateBadgeStatusItems() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .businessBarPreferencesDidChange)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.startMinuteRefreshTimer() // restarts/stops based on feature flag
                    self?.updateMainStatusItem()
                    self?.updateBadgeStatusItems()
                    if let menu = self?.mainStatusItem?.menu {
                        self?.menuWillOpen(menu)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Minute refresh timer (power-efficient)

    /// Starts the 60-second refresh timer only when the calendar feature is
    /// enabled.  When the feature is off the timer is a waste of CPU cycles
    /// since there is no event text to keep up-to-date.
    private func startMinuteRefreshTimer() {
        stopMinuteRefreshTimer()
        guard isCalendarFeatureEnabled else { return }
        minuteRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.meetingManager.recalculateNextEvent()
                self?.updateMainStatusItem()
            }
        }
    }

    private func stopMinuteRefreshTimer() {
        minuteRefreshTimer?.invalidate()
        minuteRefreshTimer = nil
    }

    private func updateMainStatusItem() {
        guard let button = mainStatusItem?.button else { return }

        // Always start from a clean slate so stale state from a previous branch
        // never bleeds through into the new layout.
        button.image = nil
        button.imagePosition = .imageLeft
        button.attributedTitle = NSAttributedString()
        button.contentTintColor = nil

        let nextEventToShow = isCalendarFeatureEnabled ? meetingManager.nextEvent : nil
        let shouldShowNoSleep = noSleepManager.isActive && isNoSleepFeatureEnabled

        // ── Display logic ──────────────────────────────────────────────
        //
        //  Meeting only    → text only ("Team Standup in 12m"), no icon
        //  NoSleep only    → coffee cup icon with ∞ or clock badge
        //  Both active     → meeting text + NoSleep cup icon (imageRight)
        //  Idle (nothing)  → branded calendar icon (same color as AppIcon)
        //

        if shouldShowNoSleep {
            // NoSleep icon: ☕∞ for infinite, ☕🕐 for scheduled
            button.image = makeNoSleepStatusImage()

            if let nextEvent = nextEventToShow {
                // NoSleep + meeting: meeting text with cup icon on the right
                button.imagePosition = .imageRight
                button.attributedTitle = makeMeetingAttributedString(for: nextEvent)
            } else {
                // NoSleep only: just the cup icon, no text
                button.imagePosition = .imageOnly
            }
        } else if let nextEvent = nextEventToShow {
            // Meeting only: text, no icon
            button.imagePosition = .noImage
            button.attributedTitle = makeMeetingAttributedString(for: nextEvent)
        } else {
            // Idle: branded calendar icon matching the AppIcon's style
            button.image = cachedAppIcon
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Status bar image/title helpers

    /// Composite icon for the NoSleep status bar item.
    ///
    ///   ☕∞  — infinite NoSleep (cup + infinity symbol)
    ///   ☕🕐 — scheduled NoSleep (cup + clock symbol)
    ///
    /// The cup is rendered in white with a small badge overlay indicating
    /// the mode. `isTemplate = false` ensures AppKit never silhouettes the
    /// glyphs, so the icon is always visible in both light and dark menu bars.
    private func makeNoSleepStatusImage() -> NSImage {
        let isInfinite = noSleepManager.timeRemaining.isInfinite

        if isInfinite, let cached = cachedNoSleepInfiniteIcon { return cached }
        if !isInfinite, let cached = cachedNoSleepTimedIcon { return cached }

        let modeSymbol = isInfinite ? "infinity" : "clock"

        // Layout: cup (16pt) + gap (2pt) + badge (10pt)
        let cupSize:   CGFloat = 16
        let badgeSize: CGFloat = 10
        let gap:       CGFloat = 2
        let totalW:    CGFloat = cupSize + gap + badgeSize
        let totalH:    CGFloat = 18

        let result = NSImage(size: NSSize(width: totalW, height: totalH),
                             flipped: false) { _ in
            let white = NSImage.SymbolConfiguration(paletteColors: [.white])

            // Draw the coffee cup
            let cupConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(white)
            if let cup = NSImage(systemSymbolName: "cup.and.heat.waves",
                                 accessibilityDescription: nil)?
                .withSymbolConfiguration(cupConfig) {
                cup.isTemplate = false
                let y = (totalH - cupSize) / 2
                cup.draw(in: NSRect(x: 0, y: y, width: cupSize, height: cupSize))
            }

            // Draw the mode badge (∞ or 🕐)
            let badgeConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
                .applying(white)
            if let badge = NSImage(systemSymbolName: modeSymbol,
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeConfig) {
                badge.isTemplate = false
                let y = (totalH - badgeSize) / 2
                badge.draw(in: NSRect(x: cupSize + gap, y: y, width: badgeSize, height: badgeSize))
            }

            return true
        }
        result.isTemplate = false

        if isInfinite { cachedNoSleepInfiniteIcon = result }
        else { cachedNoSleepTimedIcon = result }
        return result
    }

    /// Renders the "Bb" text icon as a white-on-transparent template image.
    /// Only used as a last-resort fallback if the asset-catalog icon is missing.
    private static func renderFallbackIcon() -> NSImage? {
        let iconSize = NSSize(width: 18, height: 18)
        let icon = NSImage(size: iconSize, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            let font = NSFont(name: "SF Pro Display SemiBold", size: 12)
                ?? NSFont.systemFont(ofSize: 12, weight: .semibold)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]

            let text = NSAttributedString(string: "Bb", attributes: attributes)
            let textSize = text.size()
            let textRect = NSRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2 - 1,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect)

            return true
        }
        icon.isTemplate = true
        return icon
    }

    /// Renders the calendar.badge.clock SF Symbol in the app's brand color
    /// (blue/purple matching the AppIcon) as a non-template image.
    ///
    /// This is the idle icon — shown when no meeting or NoSleep is active.
    /// Using the brand color instead of a template image makes the status bar
    /// icon visually consistent with the app icon in Finder/Launchpad.
    private static func renderBrandedIcon() -> NSImage? {
        // Brand color matching the AppIcon's blue/purple (RGB ~70, 80, 170).
        let brandColor = NSColor(red: 70/255, green: 80/255, blue: 170/255, alpha: 1.0)
        let white = NSColor.white

        let iconSize = NSSize(width: 20, height: 20)

        let icon = NSImage(size: iconSize, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            // Render the calendar.badge.clock symbol using palette colors
            // so the main body is the brand color and the badge is white.
            let paletteConfig = NSImage.SymbolConfiguration(
                paletteColors: [brandColor, white]
            )
            let sizeConfig = NSImage.SymbolConfiguration(
                pointSize: 16, weight: .medium
            )
            let config = paletteConfig.applying(sizeConfig)

            guard let symbol = NSImage(
                systemSymbolName: "calendar.badge.clock",
                accessibilityDescription: "BusinessBar"
            )?.withSymbolConfiguration(config) else { return false }

            symbol.isTemplate = false
            let symbolSize = symbol.size
            let origin = NSPoint(
                x: (rect.width - symbolSize.width) / 2,
                y: (rect.height - symbolSize.height) / 2
            )
            symbol.draw(in: NSRect(origin: origin, size: symbolSize))

            return true
        }
        icon.isTemplate = false
        return icon
    }

    /// NoSleep remaining time as a compact string for tooltip or accessibility.
    /// Returns "∞" for infinite or "1h 23m" / "45m" for scheduled durations.
    private var noSleepTimeDescription: String {
        if noSleepManager.timeRemaining.isInfinite {
            return "∞"
        }
        let totalSeconds = Int(noSleepManager.timeRemaining)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Truncated meeting title + countdown/remaining-time string.
    private func makeMeetingAttributedString(for event: CalendarEvent) -> NSAttributedString {
        let titleMaxLength = UserDefaults.standard.integer(forKey: Constants.Defaults.meetingTitleMaxLength)
        let maxLength = titleMaxLength > 0 ? titleMaxLength : Constants.DefaultValues.meetingTitleMaxLength
        let title = event.title.truncated(to: maxLength)
        let timeString = formatEventTime(event)
        return NSAttributedString(string: "\(title) \(timeString)  ")
    }

    private func formatEventTime(_ event: CalendarEvent) -> String {
        switch currentEventTimeMode {
        case .relative:
            let now = Date()

            if event.isHappening {
                let remaining = event.endDate.timeIntervalSince(now)
                let minutes = Int(remaining / 60)
                return "(ends \(minutes)m)"
            } else {
                let timeUntil = event.startDate.timeIntervalSince(now)
                let minutes = Int(timeUntil / 60)

                if minutes < 60 {
                    return "in \(minutes)m"
                } else {
                    let hours = minutes / 60
                    return "in \(hours)h"
                }
            }

        case .absolute:
            let fmt = Self.absoluteTimeFormatter
            let start = fmt.string(from: event.startDate)
            let end = fmt.string(from: event.endDate)
            return "(\(start)-\(end))"
        }
    }

    private func updateBadgeStatusItems() {
        guard isBadgeFeatureEnabled else {
            for item in badgeStatusItems.values {
                NSStatusBar.system.removeStatusItem(item)
            }
            badgeStatusItems.removeAll()
            previousBadgeCounts.removeAll()
            return
        }

        let monitoredApps = badgeManager.monitoredApps
        let badges        = badgeManager.badges

        let hideWhenNotRunning     = UserDefaults.standard.bool(forKey: Constants.Defaults.hideIconWhenNotRunning)
        let hideWhenNoNotification = UserDefaults.standard.bool(forKey: Constants.Defaults.hideIconWhenNoNotification)
        let iconSize = badgeIconDimension

        // Only query running apps when the preference that needs it is enabled.
        let runningBundleIDs: Set<String> = hideWhenNotRunning
            ? Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            : []

        // Ensure a status item exists for every monitored app.
        let monitoredBundleIDs = Set(monitoredApps.map { $0.bundleIdentifier })
        let currentBundleIDs   = Set(badgeStatusItems.keys)

        // Remove status items for apps no longer in the monitored list.
        for bundleID in currentBundleIDs.subtracting(monitoredBundleIDs) {
            if let item = badgeStatusItems[bundleID] {
                NSStatusBar.system.removeStatusItem(item)
                badgeStatusItems.removeValue(forKey: bundleID)
                renderedBadgeImages.removeValue(forKey: bundleID)
            }
        }

        // Add status items for newly monitored apps.
        for bundleID in monitoredBundleIDs.subtracting(currentBundleIDs) {
            let item = NSStatusBar.system.statusItem(withLength: iconSize)
            badgeStatusItems[bundleID] = item
            if let button = item.button {
                button.target = self
                button.action = #selector(badgeStatusItemClicked(_:))
            }
        }

        // Update icon + visibility for every monitored app.
        for app in monitoredApps {
            let bundleID = app.bundleIdentifier
            guard let item = badgeStatusItems[bundleID],
                  let button = item.button else { continue }

            let count     = badges[bundleID] ?? 0
            let isRunning = runningBundleIDs.contains(bundleID)

            // Toast: show when count increases after the first observed read.
            // nil previousCount means the app was just added — record the baseline
            // without toasting so we don't fire on pre-existing unread counts.
            let previousCount = previousBadgeCounts[bundleID]
            previousBadgeCounts[bundleID] = count
            if let prev = previousCount, count > prev, count > 0 {
                showToast(for: app, count: count, anchoredTo: button)
            }

            // Hide when there are no notifications (counts as 0) and the relevant
            // preference is on. "No notification" supersedes "not running" since it
            // is the broader condition.
            let shouldHide = count == 0 && (hideWhenNoNotification || (hideWhenNotRunning && !isRunning))
            if shouldHide {
                item.length = 0
                button.image = nil
                continue
            }
            item.length = iconSize

            guard let icon = app.icon else { continue }

            let cached = renderedBadgeImages[bundleID]
            if cached?.count == count, button.image != nil {
                continue
            }

            let iconRect = NSSize(width: iconSize, height: iconSize)
            let newImage: NSImage
            if count > 0 {
                newImage = resized(icon, to: iconRect).withBadge(count: count)
            } else {
                newImage = resized(icon, to: iconRect).grayscalePreservingAlpha()
            }
            button.image = newImage
            renderedBadgeImages[bundleID] = (count: count, image: newImage)
        }
    }

    /// Returns a copy of `image` drawn into a canvas of `size`.
    private func resized(_ image: NSImage, to size: NSSize) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        result.unlockFocus()
        return result
    }

    // MARK: - Toast

    /// Shows a minimal NSPopover toast anchored to `button` when the badge count
    /// for an app increases. Replaces any currently visible toast and auto-dismisses
    /// after 3 seconds. No arrow (shouldHideAnchor), transient behavior.
    private func showToast(for app: MonitoredApp, count: Int, anchoredTo button: NSStatusBarButton) {
        // Cancel any pending dismiss and close the current toast.
        toastDismissTask?.cancel()
        toastDismissTask = nil
        activeToastPopover?.close()
        activeToastPopover = nil

        // Build the SwiftUI content and compute its ideal size.
        let hostingController = NSHostingController(rootView: ToastView(icon: app.icon, count: count))
        let contentSize = hostingController.sizeThatFits(in: NSSize(width: 300, height: 60))

        let popover = NSPopover()
        popover.behavior = .transient
        // Hide the directional arrow — the toast floats clean below the icon.
        popover.setValue(true, forKeyPath: "shouldHideAnchor")
        popover.contentSize = contentSize
        popover.contentViewController = hostingController

        // Anchor to the bottom edge of the badge status item (appears below the menu bar).
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Detach from the status item's window so the popover isn't clipped
        // by the menu bar frame (technique from the Doll reference).
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.parent?.removeChildWindow(popoverWindow)
        }

        activeToastPopover = popover

        // Schedule auto-dismiss after 3 seconds.
        let task = DispatchWorkItem { [weak self, weak popover] in
            popover?.close()
            if self?.activeToastPopover === popover {
                self?.activeToastPopover = nil
            }
        }
        toastDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    // MARK: - Badge status item actions

    @objc private func badgeStatusItemClicked(_ sender: NSStatusBarButton) {
        let bundleID = badgeStatusItems.first(where: { $0.value.button == sender })?.key

        guard let bundleID = bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private func joinMeeting(_ event: CalendarEvent) {
        guard let url = event.meetingLink else { return }
        NSWorkspace.shared.open(url)
    }

    private func showPreferences() {
        onShowPreferences()
    }

    // MARK: - Keyboard shortcuts

    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .openMenu) { [weak self] in
            self?.mainStatusItem?.button?.performClick(nil)
        }

        KeyboardShortcuts.onKeyUp(for: .joinNextMeeting) { [weak self] in
            guard let self,
                  let event = self.meetingManager.nextEvent else { return }
            self.joinMeeting(event)
        }
    }
}

// MARK: - NSMenuDelegate

extension StatusBarController: NSMenuDelegate {
    /// Called by AppKit right before the menu is displayed. At this point all
    /// @Published properties are fully committed (no willSet in flight), so we
    /// always read accurate state. This replaces the old updateMenu() + observer
    /// pattern which suffered from @Published willSet stale-value reads.
    func menuWillOpen(_ menu: NSMenu) {
        let fresh = MenuBuilder.build(
            events: meetingManager.events,
            nextEvent: meetingManager.nextEvent,
            isLoading: meetingManager.isLoading,
            noSleepManager: noSleepManager,
            onJoinMeeting: { [weak self] event in self?.joinMeeting(event) },
            onDismissEvent: { [weak self] eventID in self?.meetingManager.dismissEvent(eventID) },
            onToggleNoSleep: { [weak self] in self?.noSleepManager.toggle() },
            onActivateNoSleep: { [weak self] duration in self?.noSleepManager.activate(duration: duration) },
            onDeactivateNoSleep: { [weak self] in self?.noSleepManager.deactivate() },
            onShowPreferences: { [weak self] in self?.showPreferences() },
            onQuit: { NSApp.terminate(nil) },
            showEvents: isCalendarFeatureEnabled,
            showNoSleep: isNoSleepFeatureEnabled
        )

        // Transfer items from the freshly-built menu into the persistent menu object.
        // NSMenuItem can only belong to one NSMenu at a time, so we remove each item
        // from `fresh` before inserting it into `menu`.
        menu.removeAllItems()
        while fresh.numberOfItems > 0 {
            guard let item = fresh.item(at: 0) else { break }
            fresh.removeItem(at: 0)
            menu.addItem(item)
        }
    }
}
