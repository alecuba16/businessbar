import SwiftUI
import BusinessBarCore
import ApplicationServices
import AppKit
import Foundation
import os.log

struct NoSleepTab: View {
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var isResettingPermission = false

    @AppStorage(Constants.Defaults.featureNoSleep)            private var featureNoSleepEnabled = true
    @AppStorage(Constants.Defaults.noSleepSleepMode)         private var sleepModeRaw      = SleepMode.systemOnly.rawValue
    @AppStorage(Constants.Defaults.noSleepDefaultDuration)   private var defaultDuration   = Constants.DefaultValues.noSleepDefaultDuration
    @AppStorage(Constants.Defaults.noSleepActivateOnStart)   private var activateOnStart   = false
    @AppStorage(Constants.Defaults.noSleepDeactivateOnSleep) private var deactivateOnSleep = true
    @AppStorage(Constants.Defaults.noSleepSimulateActivity)    private var simulateActivity  = false
    @AppStorage(Constants.Defaults.activityCheckInterval)       private var checkInterval     = Constants.DefaultValues.activityCheckInterval
    @AppStorage(Constants.Defaults.activityIdleMultiplier)      private var idleMultiplier    = Constants.DefaultValues.activityIdleMultiplier

    var body: some View {
        Form {
            Section("NoSleep Feature") {
                Toggle("Enable NoSleep functionality", isOn: $featureNoSleepEnabled)
                    .onChange(of: featureNoSleepEnabled) { _, enabled in
                        AppLogger.info("NoSleep feature \(enabled ? "enabled" : "disabled")", category: "NoSleep")
                        notifyPreferencesChanged()
                    }
                Text("This kill-switch disables NoSleep controls and runtime behavior.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(accessibilityGranted ? .green : .orange)
                    Text(accessibilityGranted ? "Accessibility permission granted" : "Accessibility permission required for activity simulation")
                }

                HStack(spacing: 8) {
                    Button("Grant Permission") {
                        AppLogger.info("Requesting Accessibility permission from NoSleep tab", category: "Permissions")
                        BadgeManager.requestAccessibilityPermission()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(isResettingPermission ? "Resetting…" : "Reset Permission") {
                        resetAccessibilityPermission()
                    }
                    .disabled(isResettingPermission)
                    .buttonStyle(.bordered)
                }
            }

            Section("Sleep Prevention Mode") {
                Picker("Mode", selection: Binding(
                    get: { sleepModeRaw },
                    set: { sleepModeRaw = $0 }
                )) {
                    VStack(alignment: .leading) {
                        Text("Prevent system sleep only")
                        Text("Screen can dim and sleep. Best for battery life.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .tag(SleepMode.systemOnly.rawValue)

                    VStack(alignment: .leading) {
                        Text("Prevent system + display sleep")
                        Text("Nothing sleeps. Use when presenting.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .tag(SleepMode.systemAndDisplay.rawValue)
                }
                .pickerStyle(.radioGroup)
            }
            .disabled(!featureNoSleepEnabled)

            Section("Default Duration") {
                Picker("Duration", selection: $defaultDuration) {
                    Text("Infinite").tag(0)
                    Divider()
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("5 hours").tag(300)
                }
            }
            .disabled(!featureNoSleepEnabled)

            Section("Behavior") {
                Toggle("Activate when starting BusinessBar", isOn: $activateOnStart)
                Toggle("Deactivate when device sleeps manually", isOn: $deactivateOnSleep)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Keep apps active (simulate activity)", isOn: $simulateActivity)
                        .disabled(!accessibilityGranted)
                        .onChange(of: simulateActivity) { _, _ in
                            postSimulateActivityChanged()
                        }

                    Text("Prevents apps showing \"Away\" status. Requires Accessibility permission.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if simulateActivity {
                        Divider()
                            .padding(.top, 2)

                        Picker("Check every", selection: $checkInterval) {
                            Text("15 seconds").tag(15)
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("2 minutes").tag(120)
                        }
                        .onChange(of: checkInterval) { _, _ in
                            postSimulateActivityChanged()
                        }

                        Picker("Simulate if idle for", selection: $idleMultiplier) {
                            ForEach([2, 3, 4, 5, 6, 8, 10], id: \.self) { mult in
                                Text("×\(mult) — \(formattedDuration(checkInterval * mult))")
                                    .tag(mult)
                            }
                        }
                        .onChange(of: idleMultiplier) { _, _ in
                            postSimulateActivityChanged()
                        }

                        Text("Idle threshold = \(idleMultiplier) × \(formattedDuration(checkInterval)) = \(formattedDuration(checkInterval * idleMultiplier))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(!featureNoSleepEnabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityStatus()
        }
    }

    // MARK: - Helpers

    private func postSimulateActivityChanged() {
        NotificationCenter.default.post(name: .noSleepSimulateActivityChanged, object: nil)
    }

    private func notifyPreferencesChanged() {
        NotificationCenter.default.post(name: .businessBarPreferencesDidChange, object: nil)
    }

    private func refreshAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        if !accessibilityGranted {
            AppLogger.warning("Accessibility permission not granted — disabling activity simulation", category: "Permissions")
            simulateActivity = false
            postSimulateActivityChanged()
        }
    }

    private func resetAccessibilityPermission() {
        guard !isResettingPermission else { return }
        isResettingPermission = true
        simulateActivity = false
        postSimulateActivityChanged()

        AppLogger.info("Resetting Accessibility permission via tccutil from NoSleep tab", category: "Permissions")

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "Accessibility", Constants.bundleIdentifier]
            do {
                try task.run()
                task.waitUntilExit()
                AppLogger.info("Accessibility permission reset completed (exit code: \(task.terminationStatus))", category: "Permissions")
            } catch {
                AppLogger.error("Failed to run tccutil for Accessibility reset: \(error.localizedDescription)", category: "Permissions")
            }
            DispatchQueue.main.async {
                isResettingPermission = false
                refreshAccessibilityStatus()
            }
        }
    }

    /// Formats a duration in seconds to a human-readable string: "45s", "2m", "1m 30s".
    private func formattedDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds % 60 == 0 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
    }
}
