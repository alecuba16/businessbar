import ApplicationServices
import AppKit
import BusinessBarCore
import EventKit
import SwiftUI
import UserNotifications

struct PermissionsStep: View {
    struct PermissionStatus {
        var calendar: Bool
        var notifications: Bool
        var accessibility: Bool
    }

    let onBack: () -> Void
    let onNext: () -> Void
    private let permissionStatus: () async -> PermissionStatus
    /// Test seams: the coverage fixture runs as a bare executable where the
    /// real notification center answers nothing and EventKit grants nothing,
    /// so status/authorization/open-URL round trips are injectable.
    private let requestCalendarAccessTask: () async throws -> Bool
    private let notificationCenterStatus: (@escaping (UNAuthorizationStatus) -> Void) -> Void
    private let notificationCenterRequest: (@escaping (Bool) -> Void) -> Void
    private let openNotificationSettingsURL: (URL) -> Void
    private let isRuntimeBundlePresent: Bool
    private let requestAccessibility: @MainActor () -> Void
    private let accessibilityRefreshDelay: () async -> Void

    init(
        onBack: @escaping () -> Void,
        onNext: @escaping () -> Void,
        permissionStatus: @escaping () async -> PermissionStatus = { await Self.livePermissionStatus() },
        requestCalendarAccessTask: @escaping () async throws -> Bool = {
            let adapter = EKEventStoreAdapter()
            return try await adapter.requestAccess()
        },
        notificationCenterStatus: @escaping (@escaping (UNAuthorizationStatus) -> Void) -> Void = { receive in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                receive(settings.authorizationStatus)
            }
        },
        notificationCenterRequest: @escaping (@escaping (Bool) -> Void) -> Void = { receive in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                receive(granted)
            }
        },
        openNotificationSettingsURL: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        },
        isRuntimeBundlePresent: Bool = RuntimeBundle.isPresent,
        requestAccessibility: @escaping @MainActor () -> Void = { BadgeManager.requestAccessibilityPermission() },
        accessibilityRefreshDelay: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) {
        self.onBack = onBack
        self.onNext = onNext
        self.permissionStatus = permissionStatus
        self.requestCalendarAccessTask = requestCalendarAccessTask
        self.notificationCenterStatus = notificationCenterStatus
        self.notificationCenterRequest = notificationCenterRequest
        self.openNotificationSettingsURL = openNotificationSettingsURL
        self.isRuntimeBundlePresent = isRuntimeBundlePresent
        self.requestAccessibility = requestAccessibility
        self.accessibilityRefreshDelay = accessibilityRefreshDelay
    }

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
                        .accessibilityLabel("NoSleep")
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
                    .accessibilityLabel(title)
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
        Task { @MainActor in
            await refreshPermissions()
        }
    }

    @MainActor
    private func refreshPermissions() async {
        let status = await permissionStatus()
        calendarGranted = status.calendar
        notificationsGranted = status.notifications
        accessibilityGranted = status.accessibility
        if !calendarGranted { featureCalendarEnabled = false }
        if !notificationsGranted { featureNotificationsEnabled = false }
        if !accessibilityGranted { featureBadgesEnabled = false }
    }

    static func livePermissionStatus() async -> PermissionStatus {
        let notifications: Bool
        if RuntimeBundle.isPresent {
            notifications = await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    continuation.resume(returning: [.authorized, .provisional].contains(settings.authorizationStatus))
                }
            }
        } else {
            notifications = false
        }
        let calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return PermissionStatus(calendar: calendar, notifications: notifications, accessibility: AXIsProcessTrustedWithOptions(options))
    }

    private func requestCalendarAccess() {
        Task {
            do {
                let granted = try await requestCalendarAccessTask()
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
        guard isRuntimeBundlePresent else { return }
        notificationCenterStatus { status in
            switch status {
            case .denied:
                Task { @MainActor in
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        openNotificationSettingsURL(url)
                    }
                }
            case .authorized, .provisional:
                Task { @MainActor in
                    notificationsGranted = true
                    featureNotificationsEnabled = true
                }
            case .notDetermined:
                notificationCenterRequest { granted in
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
        requestAccessibility()
        Task { @MainActor in
            await accessibilityRefreshDelay()
            await refreshPermissions()
            if accessibilityGranted {
                featureBadgesEnabled = true
            }
        }
    }
}
