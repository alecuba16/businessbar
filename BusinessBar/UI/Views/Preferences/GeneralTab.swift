import BusinessBarCore
import KeyboardShortcuts
import os.log
import ServiceManagement
import SwiftUI
import UserNotifications
import Foundation

struct GeneralTab: View {
    // Sparkle updater passed in from AppDelegate via environment
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    // Reflects actual launch-at-login state — updated after every toggle.
    @State private var launchAtLogin: Bool = LaunchAtLoginHelper.isEnabled

    // MARK: - Logging configuration
    @AppStorage(Constants.Defaults.loggingEnabled)     private var loggingEnabled     = true
    @AppStorage(Constants.Defaults.fileLoggingEnabled)  private var fileLoggingEnabled = true
    @AppStorage(Constants.Defaults.logLevelRaw)         private var logLevelRaw        = Constants.DefaultValues.logLevelRaw

    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            // MARK: General
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLoginHelper.setEnabled(enabled)
                        launchAtLogin = LaunchAtLoginHelper.isEnabled
                        AppLogger.info("Launch at login \(enabled ? "enabled" : "disabled")", category: "General")
                    }

                Toggle("Check for updates automatically",
                       isOn: $updaterViewModel.automaticallyChecksForUpdates)

                Button("Check for Updates Now") {
                    updaterViewModel.checkForUpdates()
                }
                .disabled(!updaterViewModel.canCheckForUpdates)
            }

            // MARK: Keyboard shortcuts
            Section("Keyboard Shortcuts") {
                KeyboardShortcuts.Recorder("Join meeting:", name: .joinNextMeeting)
                KeyboardShortcuts.Recorder("Open menu:",   name: .openMenu)
            }

            // MARK: Logging
            Section("Logging") {
                Toggle("Enable logging", isOn: $loggingEnabled)
                    .onChange(of: loggingEnabled) { _, enabled in
                        AppLogger.info("Logging \(enabled ? "enabled" : "disabled")", category: "Logging")
                    }

                Text("Controls whether BusinessBar writes diagnostic logs. Disable for maximum power efficiency.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Write logs to disk", isOn: $fileLoggingEnabled)
                    .disabled(!loggingEnabled)
                    .onChange(of: fileLoggingEnabled) { _, enabled in
                        AppLogger.info("File logging \(enabled ? "enabled" : "disabled")", category: "Logging")
                    }

                Text("Persists error and fatal logs to ~/Library/Logs/BusinessBar/ with rotation (5 files, 1 MB each).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Minimum log level:", selection: $logLevelRaw) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.userDescription).tag(level.rawValue)
                    }
                }
                .disabled(!loggingEnabled)
                .onChange(of: logLevelRaw) { _, newRaw in
                    if let level = LogLevel(rawValue: newRaw) {
                        AppLogger.info("Log level changed to \(level.description)", category: "Logging")
                    }
                }

                HStack(spacing: 4) {
                    Text("Energy impact:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(energyImpactLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(energyImpactColor)
                }

                Button("Open Log Directory in Finder") {
                    openLogDirectory()
                }
                .disabled(!fileLoggingEnabled || !loggingEnabled)
            }

            // MARK: Reset
            Section {
                Button("Reset All Settings to Defaults") {
                    showingResetConfirmation = true
                }
                .foregroundColor(.red)
            } footer: {
                Text("Removes all app data and relaunches BusinessBar as a fresh install.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        .confirmationDialog(
            "Reset All Settings?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetAllSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears all settings, saved data, Google sign-in state, and attempts to reset granted permissions before relaunching BusinessBar.")
        }
    }

    // MARK: - Logging helpers

    private var currentLogLevel: LogLevel {
        LogLevel(rawValue: logLevelRaw) ?? .warning
    }

    private var energyImpactLabel: String {
        guard loggingEnabled else { return "None" }
        switch currentLogLevel {
        case .debug:   return "High"
        case .info:    return "Medium"
        case .warning: return "Very Low"
        case .error:   return "Minimal"
        case .fatal:   return "Minimal"
        }
    }

    private var energyImpactColor: Color {
        guard loggingEnabled else { return .green }
        switch currentLogLevel {
        case .debug:   return .orange
        case .info:    return .yellow
        case .warning: return .green
        case .error:   return .green
        case .fatal:   return .green
        }
    }

    private func openLogDirectory() {
        let logDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BusinessBar", isDirectory: true)

        guard let url = logDir else { return }

        // Ensure the directory exists before revealing it
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // MARK: - Reset

    private func resetAllSettings() {
        AppLogger.fatal("User triggered full settings reset — all data will be erased", category: "General")

        // A fresh install is not configured for launch at login.
        LaunchAtLoginHelper.setEnabled(false)

        // Wipe all persisted defaults (including onboarding and user data).
        UserDefaults.standard.removePersistentDomain(forName: Constants.bundleIdentifier)
        UserDefaults.standard.registerDefaults()

        // Remove any saved Google OAuth state from keychain.
        do {
            try KeychainHelper.delete(key: GoogleAuthConfig.keychainKey)
            AppLogger.info("Google OAuth keychain entry removed", category: "General")
        } catch {
            AppLogger.error("Failed to remove Google OAuth keychain entry: \(error.localizedDescription)", category: "General")
        }

        // Clear any scheduled/delivered notifications.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            AppLogger.info("All notifications cleared", category: "General")
        }

        // Best-effort reset of macOS privacy grants for this bundle id.
        resetTCCPermissions()
        cleanupUserLibraryArtifacts()

        // Keep UI bindings in sync just before relaunch.
        updaterViewModel.automaticallyChecksForUpdates = false
        launchAtLogin = false
        UserDefaults.standard.synchronize()
        AppLogger.info("App state reset to fresh install — relaunching", category: "General")

        restartApp()
    }

    private func resetTCCPermissions() {
        AppLogger.info("Resetting all TCC permissions via tccutil", category: "Permissions")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "All", Constants.bundleIdentifier]
        do {
            try task.run()
            task.waitUntilExit()
            AppLogger.info("TCC permission reset completed (exit code: \(task.terminationStatus))", category: "Permissions")
        } catch {
            AppLogger.error("Failed to run tccutil for TCC reset: \(error.localizedDescription)", category: "Permissions")
        }
    }

    private func cleanupUserLibraryArtifacts() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundleID = Constants.bundleIdentifier

        // Explicit known paths we own.
        let explicitPaths: [URL] = [
            home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist"),
            home.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
            home.appendingPathComponent("Library/Application Support/\(Constants.appName)"),
            home.appendingPathComponent("Library/Application Support/\(bundleID)"),
            home.appendingPathComponent("Library/Caches/\(Constants.appName)"),
            home.appendingPathComponent("Library/Caches/\(bundleID)"),
            home.appendingPathComponent("Library/Logs/\(Constants.appName)"),
            home.appendingPathComponent("Library/Logs/\(bundleID)"),
            home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        ]

        for url in explicitPaths {
            removeItemIfExists(url)
        }
        AppLogger.info("Cleaned up explicit library paths for \(bundleID)", category: "General")

        // Remove possible variant plist names that still belong to this bundle.
        removeChildren(in: home.appendingPathComponent("Library/LaunchAgents"), matchingPrefix: bundleID)
        removeChildren(in: home.appendingPathComponent("Library/Preferences"), matchingPrefix: bundleID)
        removeChildren(in: home.appendingPathComponent("Library/Preferences/ByHost"), matchingPrefix: bundleID)
    }

    private func removeItemIfExists(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
            AppLogger.debug("Removed: \(url.path)", category: "General")
        } catch {
            AppLogger.error("Failed to remove \(url.path): \(error.localizedDescription)", category: "General")
        }
    }

    private func removeChildren(in directory: URL, matchingPrefix prefix: String) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.hasPrefix(prefix) {
            removeItemIfExists(child)
        }
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
                if let error {
                    AppLogger.fatal("Failed to relaunch app bundle: \(error.localizedDescription)", category: "General")
                }
                NSApp.terminate(nil)
            }
            return
        }

        // Dev fallback when running as a bare executable.
        let executablePath = ProcessInfo.processInfo.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        do {
            try task.run()
            AppLogger.info("Relaunching as bare executable: \(executablePath)", category: "General")
        } catch {
            AppLogger.fatal("Failed to relaunch executable: \(error.localizedDescription)", category: "General")
        }
        NSApp.terminate(nil)
    }

}

// MARK: - LaunchAtLoginHelper

/// Handles launch-at-login registration using two strategies:
///   • Running as a proper .app bundle  → SMAppService.mainApp (macOS 13+, preferred)
///   • Development / bare binary build  → LaunchAgent plist in ~/Library/LaunchAgents/
enum LaunchAtLoginHelper {
    private static let launchAgentID  = "com.businessbar.app"
    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentID).plist")
    }

    private static var isBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    // MARK: - Public API

    static var isEnabled: Bool {
        if isBundle {
            return SMAppService.mainApp.status == .enabled
        } else {
            return FileManager.default.fileExists(atPath: launchAgentURL.path)
        }
    }

    static func setEnabled(_ enabled: Bool) {
        if isBundle {
            setBundleEnabled(enabled)
        } else {
            setLaunchAgentEnabled(enabled)
        }
    }

    // MARK: - SMAppService path (bundled .app)

    private static func setBundleEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                AppLogger.info("SMAppService registered — status: \(SMAppService.mainApp.status.rawValue)", category: "LaunchAtLogin")
            } else {
                try SMAppService.mainApp.unregister()
                AppLogger.info("SMAppService unregistered — status: \(SMAppService.mainApp.status.rawValue)", category: "LaunchAtLogin")
            }
        } catch {
            AppLogger.error("LaunchAtLogin \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)", category: "LaunchAtLogin")
        }
    }

    // MARK: - LaunchAgent plist path (bare / dev binary)

    private static func setLaunchAgentEnabled(_ enabled: Bool) {
        if enabled {
            writeLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    private static func writeLaunchAgent() {
        let executablePath = ProcessInfo.processInfo.arguments[0]
        let plist: [String: Any] = [
            "Label":            launchAgentID,
            "ProgramArguments": [executablePath],
            "RunAtLoad":        true,
            "KeepAlive":        false
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: launchAgentURL, options: .atomic)
            AppLogger.info("LaunchAgent written: \(launchAgentURL.path) — will launch: \(executablePath)", category: "LaunchAtLogin")
        } catch {
            AppLogger.error("Failed to write LaunchAgent: \(error.localizedDescription)", category: "LaunchAtLogin")
        }
    }

    private static func removeLaunchAgent() {
        do {
            try FileManager.default.removeItem(at: launchAgentURL)
            AppLogger.info("LaunchAgent removed: \(launchAgentURL.path)", category: "LaunchAtLogin")
        } catch {
            AppLogger.error("Failed to remove LaunchAgent: \(error.localizedDescription)", category: "LaunchAtLogin")
        }
    }
}
