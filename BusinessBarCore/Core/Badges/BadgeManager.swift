import ApplicationServices
import AppKit
import Combine
import Foundation
import os.log

@MainActor
public final class BadgeManager: ObservableObject {
    @Published public private(set) var monitoredApps: [MonitoredApp] = []
    @Published public private(set) var badges: [String: Int] = [:]
    /// Reflects `AXIsProcessTrusted()` — updated every 2 s via a poll timer.
    @Published public private(set) var isAccessibilityGranted: Bool = false

    private static let logger = Logger(subsystem: "com.businessbar.app", category: "Badge")

    private let badgeMonitor = BadgeMonitor()
    private var cancellables = Set<AnyCancellable>()
    /// Timer that polls AX trust status until permission is granted, then
    /// auto-starts monitoring and stops itself.
    private var axPermissionTimer: Timer?
    private var lastFeatureState: Bool

    public init() {
        self.lastFeatureState = Self.badgeFeatureEnabled()
        loadMonitoredApps()
        setupBadgeMonitor()
        setupPreferencesObserver()
        isAccessibilityGranted = AXIsProcessTrusted()
        Self.logger.info("init — AX trusted: \(self.isAccessibilityGranted), loaded \(self.monitoredApps.count) app(s): \(self.monitoredApps.map { $0.bundleIdentifier })")
        guard Self.badgeFeatureEnabled() else {
            badgeMonitor.stopMonitoring()
            return
        }
        if isAccessibilityGranted {
            startMonitoring()
        } else {
            Self.logger.info("init — AX permission not granted, starting permission polling")
            startPermissionPolling()
        }
    }

    // MARK: - Public API

    public func addApp(_ app: MonitoredApp) {
        guard !monitoredApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
            Self.logger.debug("addApp — skipped (already monitored): \(app.bundleIdentifier)")
            return
        }
        Self.logger.info("addApp — \(app.bundleIdentifier) (\(app.displayName))")
        monitoredApps.append(app)
        saveMonitoredApps()
        if Self.badgeFeatureEnabled() {
            updateMonitoring()
        }
    }

    public func removeApp(_ bundleIdentifier: String) {
        Self.logger.info("removeApp — \(bundleIdentifier)")
        monitoredApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        badges.removeValue(forKey: bundleIdentifier)
        saveMonitoredApps()
        if Self.badgeFeatureEnabled() {
            updateMonitoring()
        }
    }

    /// Open System Settings to the Accessibility privacy pane.
    public func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Prompt the user for AX access (shows the system dialog on older macOS;
    /// on macOS 14+ opens System Settings automatically).
    public func requestAccessibilityPermission() {
        BadgeMonitor.requestAccessibilityPermission()
        if Self.badgeFeatureEnabled() {
            startPermissionPolling()   // begin checking in case they grant it
        }
    }

    /// Static convenience for requesting AX permission without a BadgeManager instance
    /// (e.g. from the onboarding flow before any monitored apps are configured).
    public static func requestAccessibilityPermission() {
        BadgeMonitor.requestAccessibilityPermission()
    }

    // MARK: - Permission polling

    /// Polls `AXIsProcessTrusted()` every 2 s. Once granted, starts monitoring
    /// and cancels the timer.
    private func startPermissionPolling() {
        guard axPermissionTimer == nil else { return }
        // Don't waste CPU polling for a permission that won't be used.
        guard Self.badgeFeatureEnabled() else { return }
        axPermissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAccessibilityPermission()
            }
        }
    }

    private func stopPermissionPolling() {
        axPermissionTimer?.invalidate()
        axPermissionTimer = nil
    }

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        let wasGranted = isAccessibilityGranted
        isAccessibilityGranted = trusted
        guard Self.badgeFeatureEnabled() else {
            // Feature was disabled while we were polling — stop the timer
            // so we don't keep waking up every 2 s for nothing.
            stopPermissionPolling()
            return
        }
        if trusted && !wasGranted {
            Self.logger.info("Accessibility permission granted — starting monitoring")
            startMonitoring()
            stopPermissionPolling()
        }
    }

    // MARK: - Badge monitor wiring

    private func setupBadgeMonitor() {
        badgeMonitor.onBadgeUpdate = { [weak self] bundleID, count in
            Task { @MainActor [weak self] in
                self?.updateBadge(for: bundleID, count: count)
            }
        }
    }

    private func updateBadge(for bundleID: String, count: Int) {
        let previous = badges[bundleID] ?? 0
        if count != previous {
            Self.logger.debug("badge changed — \(bundleID): \(previous) → \(count)")
        }
        if count > 0 {
            badges[bundleID] = count
        } else {
            badges.removeValue(forKey: bundleID)
        }
        if let index = monitoredApps.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
            monitoredApps[index].badgeCount = count
        }
    }

    private func startMonitoring() {
        Self.logger.info("startMonitoring — \(self.monitoredApps.count) app(s): \(self.monitoredApps.map { $0.bundleIdentifier })")
        badgeMonitor.startMonitoring(apps: self.monitoredApps)
    }

    private func updateMonitoring() {
        guard isAccessibilityGranted else {
            Self.logger.debug("updateMonitoring — skipped (AX permission not granted)")
            return
        }
        badgeMonitor.updateAppElements(for: monitoredApps)
    }

    // MARK: - Preferences observer

    private func setupPreferencesObserver() {
        NotificationCenter.default.publisher(for: .businessBarPreferencesDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let enabled = Self.badgeFeatureEnabled()
                    if enabled != self.lastFeatureState {
                        self.lastFeatureState = enabled
                    }

                    guard enabled else {
                        self.badges.removeAll()
                        self.badgeMonitor.stopMonitoring()
                        self.stopPermissionPolling()
                        return
                    }

                    if self.isAccessibilityGranted {
                        self.startMonitoring()
                        self.badgeMonitor.restartPollTimer()
                    } else {
                        self.startPermissionPolling()
                    }
                }
            }
            .store(in: &cancellables)
    }

    nonisolated private static func badgeFeatureEnabled() -> Bool {
        if let value = UserDefaults.standard.object(forKey: Constants.Defaults.featureBadges) as? Bool {
            return value
        }
        return true
    }

    // MARK: - Persistence

    private func loadMonitoredApps() {
        guard let data = UserDefaults.standard.data(forKey: Constants.Defaults.monitoredApps),
              let apps = try? JSONDecoder().decode([MonitoredApp].self, from: data) else {
            return
        }
        monitoredApps = apps
    }

    private func saveMonitoredApps() {
        guard let data = try? JSONEncoder().encode(monitoredApps) else { return }
        UserDefaults.standard.set(data, forKey: Constants.Defaults.monitoredApps)
    }
}
