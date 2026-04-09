import ApplicationServices
import AppKit
import BusinessBarCore
import EventKit
import SwiftUI
import UserNotifications

struct PermissionsStep: View {
    let onBack: () -> Void
    let onNext: () -> Void

    @AppStorage(Constants.Defaults.featureCalendar) private var featureCalendarEnabled = false
    @AppStorage(Constants.Defaults.featureNoSleep) private var featureNoSleepEnabled = false
    @AppStorage(Constants.Defaults.featureBadges) private var featureBadgesEnabled = false
    @AppStorage(Constants.Defaults.featureNotifications) private var featureNotificationsEnabled = false

    @State private var calendarGranted = false
    @State private var notificationsGranted = false
    @State private var accessibilityGranted = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Permissions & Features")
                .font(.largeTitle)
                .bold()

            Text("Grant only what you want. Features stay disabled until required permissions are available.")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                setupRow(
                    icon: "calendar",
                    title: "Calendar",
                    description: "Shows next meetings and meeting list in the menu bar.",
                    isGranted: calendarGranted,
                    isEnabled: $featureCalendarEnabled,
                    requestPermission: requestCalendarAccess
                )

                setupRow(
                    icon: "bell",
                    title: "Meeting Notifications",
                    description: "Schedules meeting reminders.",
                    isGranted: notificationsGranted,
                    isEnabled: $featureNotificationsEnabled,
                    requestPermission: requestNotificationAccess
                )

                setupRow(
                    icon: "app.badge",
                    title: "Badge Monitoring",
                    description: "Reads dock badge counts from monitored apps.",
                    isGranted: accessibilityGranted,
                    isEnabled: $featureBadgesEnabled,
                    requestPermission: requestAccessibilityAccess
                )

                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "cup.and.heat.waves")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("NoSleep")
                            .font(.headline)
                        Text("No extra permission required for core sleep prevention.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $featureNoSleepEnabled)
                        .labelsHidden()
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            Text("Further setup like selecting calendars and adding apps can be managed later in Preferences.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            HStack {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Finish") {
                    onNext()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding(40)
        .onAppear(perform: checkPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
    }

    @ViewBuilder
    private func setupRow(
        icon: String,
        title: String,
        description: String,
        isGranted: Bool,
        isEnabled: Binding<Bool>,
        requestPermission: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
            } else {
                Button("Grant Permission", action: requestPermission)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .onChange(of: isGranted) { _, granted in
            if !granted {
                isEnabled.wrappedValue = false
            }
        }
    }

    private func checkPermissions() {
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarGranted = status == .fullAccess
        if !calendarGranted {
            featureCalendarEnabled = false
        }

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                Task { @MainActor in
                    notificationsGranted = isNotificationStatusGranted(settings.authorizationStatus)
                    if !notificationsGranted {
                        featureNotificationsEnabled = false
                    }
                }
            }
        } else {
            notificationsGranted = false
            featureNotificationsEnabled = false
        }

        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted {
            featureBadgesEnabled = false
        }
    }

    private func requestCalendarAccess() {
        Task {
            let adapter = EKEventStoreAdapter()
            do {
                let granted = try await adapter.requestAccess()
                await MainActor.run {
                    calendarGranted = granted
                    featureCalendarEnabled = granted
                }
            } catch {
                await MainActor.run {
                    calendarGranted = false
                    featureCalendarEnabled = false
                }
            }
        }
    }

    private func requestNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .denied:
                Task { @MainActor in
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    notificationsGranted = true
                    featureNotificationsEnabled = true
                }
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    Task { @MainActor in
                        notificationsGranted = granted
                        featureNotificationsEnabled = granted
                    }
                }
            @unknown default:
                Task { @MainActor in
                    notificationsGranted = false
                    featureNotificationsEnabled = false
                }
            }
        }
    }

    private func requestAccessibilityAccess() {
        BadgeManager.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            checkPermissions()
            if accessibilityGranted {
                featureBadgesEnabled = true
            }
        }
    }

    private func isNotificationStatusGranted(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}
