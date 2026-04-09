import SwiftUI
import ApplicationServices
import BusinessBarCore
import Foundation
import os.log

struct BadgesTab: View {
    /// Injected from PreferencesWindow so the tab drives the shared BadgeManager
    /// rather than reading UserDefaults directly.
    @ObservedObject var badgeManager: BadgeManager

    @State private var showingAppPicker = false
    @State private var isResettingPermission = false

    @AppStorage(Constants.Defaults.featureBadges)             private var featureBadgesEnabled = true
    @AppStorage(Constants.Defaults.hideIconWhenNotRunning)     private var hideWhenNotRunning     = false
    @AppStorage(Constants.Defaults.hideIconWhenNoNotification) private var hideWhenNoNotification = false
    @AppStorage(Constants.Defaults.badgePollInterval)          private var badgePollInterval      = Constants.DefaultValues.badgePollInterval
    @AppStorage(Constants.Defaults.badgeIconSize)              private var badgeIconSize          = "small"

    var body: some View {
        Form {
            // MARK: Monitored Apps
            Section("Badges Feature") {
                Toggle("Enable badge monitoring", isOn: $featureBadgesEnabled)
                    .onChange(of: featureBadgesEnabled) { _, enabled in
                        if enabled && !badgeManager.isAccessibilityGranted {
                            AppLogger.warning("Badge feature enabled without accessibility permission — prompting user", category: "Permissions")
                            featureBadgesEnabled = false
                            badgeManager.requestAccessibilityPermission()
                            badgeManager.openAccessibilitySettings()
                        } else {
                            AppLogger.info("Badge monitoring \(enabled ? "enabled" : "disabled")", category: "Badges")
                        }
                        notifyPreferencesChanged()
                    }

                Text("When disabled, badge polling, triggers, and menu-bar icons are fully off.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Monitored Apps") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Apps to monitor:")
                        Spacer()
                        Button("Add App") {
                            if !badgeManager.isAccessibilityGranted {
                                badgeManager.requestAccessibilityPermission()
                                badgeManager.openAccessibilitySettings()
                            } else {
                                showingAppPicker = true
                            }
                        }
                        .disabled(!featureBadgesEnabled)
                    }

                    if badgeManager.monitoredApps.isEmpty {
                        Text("No apps added yet")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        List {
                            ForEach(badgeManager.monitoredApps) { app in
                                HStack {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 24, height: 24)
                                    }

                                    Text(app.displayName)

                                    Spacer()

                                    if app.badgeCount > 0 {
                                        Text("\(app.badgeCount)")
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.red)
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                    }

                                    Button {
                                        badgeManager.removeApp(app.bundleIdentifier)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: 200)
                    }
                }
            }
            .disabled(!featureBadgesEnabled)

            // MARK: Settings
            Section("Settings") {
                 Toggle("Hide icon when app is not running", isOn: $hideWhenNotRunning)
                     .onChange(of: hideWhenNotRunning) { _, _ in notifyPreferencesChanged() }
                 Toggle("Hide icon when no notifications",   isOn: $hideWhenNoNotification)
                     .onChange(of: hideWhenNoNotification) { _, _ in notifyPreferencesChanged() }

                 Picker("Badge icon size:", selection: $badgeIconSize) {
                    Text("Small (14px)").tag("small")
                    Text("Medium (18px)").tag("medium")
                }
                .pickerStyle(.radioGroup)
                .onChange(of: badgeIconSize) { _, _ in notifyPreferencesChanged() }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Badge check frequency:", selection: $badgePollInterval) {
                        Text("1 second").tag(1)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    .onChange(of: badgePollInterval) { _, _ in notifyPreferencesChanged() }

                    HStack(spacing: 4) {
                        Text("Energy impact:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(energyImpactLabel)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(energyImpactColor)
                    }
                }
            }
            .disabled(!featureBadgesEnabled)

            // MARK: Accessibility Permission
            Section("Accessibility Permission") {
                if badgeManager.isAccessibilityGranted {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Accessibility permission granted")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Accessibility permission required")
                                .font(.headline)
                        }

                        Text("BusinessBar needs Accessibility access to read dock notification badge counts.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 10) {
                            Button("Open System Settings") {
                                badgeManager.openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Request Permission") {
                                badgeManager.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)

                            Button(isResettingPermission ? "Resetting…" : "Reset Permission") {
                                resetAccessibilityPermission()
                            }
                            .disabled(isResettingPermission)
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        .sheet(isPresented: $showingAppPicker) {
            AppPickerView { app in
                badgeManager.addApp(app)
                showingAppPicker = false
            }
        }
        // Re-check permission whenever the preferences window comes to front
        // (e.g. user granted access in System Settings and switched back).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // BadgeManager's own 2-second timer handles this; no extra work needed.
            // This hook is here for future use (e.g. force-refresh UI immediately).
            _ = badgeManager.isAccessibilityGranted
        }
    }

    private var energyImpactLabel: String {
        switch badgePollInterval {
        case 1:  return "High"
        case 3:  return "Low"
        case 5:  return "Very Low"
        case 10: return "Minimal"
        default: return "Low"
        }
    }

    private var energyImpactColor: Color {
        switch badgePollInterval {
        case 1:  return .orange
        case 3:  return .green
        case 5:  return .green
        case 10: return .green
        default: return .green
        }
    }

    private func notifyPreferencesChanged() {
        NotificationCenter.default.post(name: .businessBarPreferencesDidChange, object: nil)
    }

    private func resetAccessibilityPermission() {
        guard !isResettingPermission else { return }
        isResettingPermission = true
        featureBadgesEnabled = false
        notifyPreferencesChanged()

        AppLogger.info("Resetting Accessibility permission via tccutil", category: "Permissions")

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
            }
        }
    }
}
