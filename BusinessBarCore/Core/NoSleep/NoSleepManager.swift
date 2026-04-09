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
        return max(0, endTime.timeIntervalSinceNow)
    }

    private let sleepManager        = SleepManager()
    private let activitySimulator   = ActivitySimulator()
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastFeatureState: Bool = UserDefaults.standard.bool(forKey: Constants.Defaults.featureNoSleep)
    private var isFeatureEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: Constants.Defaults.featureNoSleep) as? Bool {
            return value
        }
        return true
    }

    // MARK: - Lifecycle

    public init() {
        loadSettings()
        setupSleepObserver()
        setupSimulateActivityObserver()
        setupFeatureObserver()
    }

    deinit {
        // Schedule cleanup on the main actor; we can't call @MainActor methods synchronously from deinit
        let sm = sleepManager
        Task { @MainActor in
            sm.deactivate()
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

        isActive = true
        sleepManager.activate(mode: self.mode)

        if let duration {
            endTime = Date().addingTimeInterval(duration)
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
        sleepManager.deactivate()
        activitySimulator.stopSimulation()
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
            let defaultMinutes = UserDefaults.standard.integer(forKey: Constants.Defaults.noSleepDefaultDuration)
            let duration: TimeInterval? = defaultMinutes > 0 ? TimeInterval(defaultMinutes) * 60 : nil
            activate(duration: duration, mode: mode)
        }
    }

    // MARK: - Private timers

    private func startDurationTimer(duration: TimeInterval) {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
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
        NotificationCenter.default
            .publisher(for: .noSleepSimulateActivityChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applySimulateActivityPreference()
                }
            }
            .store(in: &cancellables)
    }

    private func setupFeatureObserver() {
        NotificationCenter.default
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
            activitySimulator.stopSimulation()
            return
        }
        let shouldSimulate = UserDefaults.standard.bool(forKey: Constants.Defaults.noSleepSimulateActivity)
        Self.logger.info("applySimulateActivityPreference — isActive: \(self.isActive), shouldSimulate: \(shouldSimulate)")
        guard isActive else { return }
        if shouldSimulate {
            guard AXIsProcessTrusted() else {
                Self.logger.warning("simulate activity skipped — accessibility permission missing")
                activitySimulator.stopSimulation()
                return
            }
            // Always stop first so a changed check interval takes effect immediately.
            activitySimulator.stopSimulation()
            activitySimulator.startSimulation()
        } else {
            activitySimulator.stopSimulation()
        }
    }

    // MARK: - Sleep detection

    private func setupSleepObserver() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSystemWillSleep()
            }
            .store(in: &cancellables)
    }

    private func handleSystemWillSleep() {
        let shouldDeactivate = UserDefaults.standard.bool(
            forKey: Constants.Defaults.noSleepDeactivateOnSleep
        )
        guard shouldDeactivate && isActive else { return }
        Self.logger.info("System will sleep — deactivating NoSleep")
        deactivate()
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let modeString = UserDefaults.standard.string(forKey: Constants.Defaults.noSleepSleepMode),
           let savedMode = SleepMode(rawValue: modeString) {
            mode = savedMode
        }
    }
}
