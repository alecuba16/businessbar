import AppKit
import ApplicationServices
import Combine
import Foundation
import os.log

// MARK: - NoSleepManager
// Manages NoSleep state: activates/deactivates sleep prevention, runs a
// countdown timer, and respects the "deactivate on manual sleep" preference.

@MainActor
public final class NoSleepManager: ObservableObject {
    @Published public private(set) var isActive = false
    @Published public private(set) var mode: SleepMode = .systemOnly

    private static let logger = Logger(subsystem: "com.businessbar.app", category: "NoSleep")

    /// Absolute end time; `.distantFuture` when duration is infinite, `.distantPast` when inactive.
    private var endTime: Date = .distantPast

    /// Computed on-demand — avoids a 1 Hz timer that would wake the CPU every second.
    public var timeRemaining: TimeInterval {
        guard isActive else { return 0 }
        if endTime == .distantFuture { return .infinity }
        return max(0, endTime.timeIntervalSince(now()))
    }

    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private let workspace: NotificationCenter
    private let trust: () -> Bool
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Timer
    private let activateSleep: (SleepMode) -> Void
    private let deactivateSleep: () -> Void
    private let startActivity: () -> Void
    private let stopActivity: () -> Void
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastFeatureState: Bool
    private var isFeatureEnabled: Bool {
        if let value = defaults.object(forKey: Constants.Defaults.featureNoSleep) as? Bool {
            return value
        }
        return true
    }

    // MARK: - Lifecycle

    public init(defaults: UserDefaults = .standard,
                notifications: NotificationCenter = .default,
                workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                trust: @escaping () -> Bool = { AXIsProcessTrusted() },
                now: @escaping () -> Date = Date.init,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Timer = { interval, action in
                    Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in action() }
                },
                activateSleep: ((SleepMode) -> Void)? = nil,
                deactivateSleep: (() -> Void)? = nil,
                startActivity: (() -> Void)? = nil,
                stopActivity: (() -> Void)? = nil) {
        precondition((activateSleep == nil) == (deactivateSleep == nil), "activateSleep and deactivateSleep must be supplied together")
        precondition((startActivity == nil) == (stopActivity == nil), "startActivity and stopActivity must be supplied together")
        self.defaults = defaults
        self.notifications = notifications
        self.workspace = workspace
        self.trust = trust
        self.now = now
        self.schedule = schedule
        let sleep = activateSleep == nil || deactivateSleep == nil ? SleepManager(workspace: workspace) : nil
        self.activateSleep = activateSleep ?? { sleep?.activate(mode: $0) }
        self.deactivateSleep = deactivateSleep ?? { sleep?.deactivate() }
        let activity = startActivity == nil || stopActivity == nil ? ActivitySimulator(defaults: defaults) : nil
        self.startActivity = startActivity ?? { activity?.startSimulation() }
        self.stopActivity = stopActivity ?? { activity?.stopSimulation() }
        self.lastFeatureState = defaults.object(forKey: Constants.Defaults.featureNoSleep) as? Bool ?? true
        loadSettings()
        setupSleepObserver()
        setupSimulateActivityObserver()
        setupFeatureObserver()
    }

    deinit {
        durationTimer?.invalidate()
        let cleanup = deactivateSleep
        let stop = stopActivity
        Task { @MainActor in
            cleanup()
            stop()
        }
    }

    // MARK: - Public API

    public func activate(duration: TimeInterval?, mode: SleepMode? = nil) {
        guard isFeatureEnabled else {
            Self.logger.info("activate ignored — NoSleep feature disabled")
            return
        }
        if let mode {
            self.mode = mode
        }

        stopTimers()
        isActive = true
        activateSleep(self.mode)

        if let duration {
            endTime = now().addingTimeInterval(duration)
            startDurationTimer(duration: duration)
            Self.logger.info("Activated — mode: \(self.mode.rawValue), duration: \(Int(duration))s")
        } else {
            endTime = .distantFuture
            Self.logger.info("Activated — mode: \(self.mode.rawValue), duration: infinite")
        }

        // Apply simulate-activity preference (observer handles live toggling;
        // calling it here covers activation from a cold start).
        applySimulateActivityPreference()
    }

    public func deactivate() {
        Self.logger.info("Deactivating")
        isActive = false
        endTime = .distantPast
        stopTimers()
        deactivateSleep()
        stopActivity()
    }

    public func toggle() {
        guard isFeatureEnabled else {
            Self.logger.info("toggle ignored — NoSleep feature disabled")
            return
        }
        if isActive {
            deactivate()
        } else {
            // Use the configured default duration. 0 = infinite (nil).
            let defaultMinutes = defaults.integer(forKey: Constants.Defaults.noSleepDefaultDuration)
            let duration: TimeInterval? = defaultMinutes > 0 ? TimeInterval(defaultMinutes) * 60 : nil
            activate(duration: duration, mode: mode)
        }
    }

    // MARK: - Private timers

    private func startDurationTimer(duration: TimeInterval) {
        durationTimer?.invalidate()
        durationTimer = schedule(duration) { [weak self] in
            Task { @MainActor [weak self] in
                self?.deactivate()
            }
        }
    }

    private func stopTimers() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Activity simulation preference observer

    /// Watches for changes to the "simulate activity" UserDefault while NoSleep is running.
    /// Uses `Task { @MainActor in }` so the call properly hops to this actor; without it
    /// the Combine sink closure is non-isolated and the @MainActor method is silently dropped.
    private func setupSimulateActivityObserver() {
        notifications
            .publisher(for: .noSleepSimulateActivityChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applySimulateActivityPreference()
                }
            }
            .store(in: &cancellables)
    }

    private func setupFeatureObserver() {
        notifications
            .publisher(for: .businessBarPreferencesDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let current = self.isFeatureEnabled
                    if current != self.lastFeatureState {
                        self.lastFeatureState = current
                        if !current {
                            self.deactivate()
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Apply the current `noSleepSimulateActivity` preference.
    /// Internal so `NoSleepTab` can call it directly via onChange (most reliable path).
    public func applySimulateActivityPreference() {
        guard isFeatureEnabled else {
            stopActivity()
            return
        }
        let shouldSimulate = defaults.bool(forKey: Constants.Defaults.noSleepSimulateActivity)
        Self.logger.info("applySimulateActivityPreference — isActive: \(self.isActive), shouldSimulate: \(shouldSimulate)")
        guard isActive else { return }
        if shouldSimulate {
            guard trust() else {
                Self.logger.warning("simulate activity skipped — accessibility permission missing")
                stopActivity()
                return
            }
            // Always stop first so a changed check interval takes effect immediately.
            stopActivity()
            startActivity()
        } else {
            stopActivity()
        }
    }

    // MARK: - Sleep detection

    private func setupSleepObserver() {
        workspace
            .publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSystemWillSleep()
            }
            .store(in: &cancellables)
    }

    func handleSystemWillSleep() {
        let shouldDeactivate = defaults.bool(
            forKey: Constants.Defaults.noSleepDeactivateOnSleep
        )
        guard shouldDeactivate && isActive else { return }
        Self.logger.info("System will sleep — deactivating NoSleep")
        deactivate()
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let modeString = defaults.string(forKey: Constants.Defaults.noSleepSleepMode),
           let savedMode = SleepMode(rawValue: modeString) {
            mode = savedMode
        }
    }
}
