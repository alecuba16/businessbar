import AppKit
import BusinessBarCore
import EventKit
import os.log
import SwiftUI
import UserNotifications

struct CalendarsTab: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var googleAuth: GoogleAuth

    @State private var selectedCalendarIDs: Set<String> = []
    @State private var calendarAuthStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var notificationsAuthorized = false
    @State private var isRequestingAccess = false
    @State private var isResettingCalendarPermission = false
    @State private var isResettingNotificationPermission = false

    @AppStorage(Constants.Defaults.featureCalendar) private var featureCalendarEnabled = true
    @AppStorage(Constants.Defaults.notificationMinutesBefore) private var notificationMinutes = Constants.DefaultValues.notificationMinutesBefore
    @AppStorage(Constants.Defaults.endOfEventNotification) private var endOfEventNotification = false
    @AppStorage(Constants.Defaults.calendarProvider) private var calendarProvider = CalendarProvider.eventKit.rawValue
    @AppStorage(Constants.Defaults.meetingTitleMaxLength) private var titleMaxLength = Constants.DefaultValues.meetingTitleMaxLength {
        didSet { notifyPreferencesChanged() }
    }
    @AppStorage(Constants.Defaults.showTomorrowEvents) private var showTomorrowEvents = true {
        didSet { notifyPreferencesChanged() }
    }
    @AppStorage(Constants.Defaults.showDeclinedEvents) private var showDeclinedEvents = false {
        didSet { notifyPreferencesChanged() }
    }
    @AppStorage(Constants.Defaults.timeFormat) private var timeFormat = "relative" {
        didSet { notifyPreferencesChanged() }
    }
    @AppStorage(Constants.Defaults.featureNotifications) private var meetingNotificationsEnabled = true {
        didSet { notifyPreferencesChanged() }
    }

    private var hasMacCalendarPermission: Bool {
        calendarAuthStatus == .fullAccess
    }

    private var canEnableCalendarFeature: Bool {
        if calendarProvider == CalendarProvider.eventKit.rawValue {
            return hasMacCalendarPermission
        }
        return GoogleAuthConfig.isConfigured && googleAuth.isAuthenticated
    }

    private var canEditCalendarConfig: Bool {
        featureCalendarEnabled && canEnableCalendarFeature
    }

    var body: some View {
        Form {
            Section("Calendar Feature") {
                Toggle("Enable calendar functionality", isOn: Binding(
                    get: { featureCalendarEnabled },
                    set: { setCalendarFeatureEnabled($0) }
                ))
                Text("This kill-switch controls event fetching, menu rendering, joins, and scheduling.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                Picker("Provider", selection: $calendarProvider) {
                    Text("macOS Calendar").tag(CalendarProvider.eventKit.rawValue)
                    Text("Google Calendar").tag(CalendarProvider.google.rawValue)
                }
                .pickerStyle(.radioGroup)

                if calendarProvider == CalendarProvider.eventKit.rawValue {
                    permissionStatusRow(
                        granted: hasMacCalendarPermission,
                        grantedText: "Calendar permission granted",
                        missingText: "Calendar permission required"
                    )

                    HStack(spacing: 8) {
                        Button(isRequestingAccess ? "Requesting…" : "Grant Permission") {
                            grantCalendarAccess()
                        }
                        .disabled(isRequestingAccess)
                        .buttonStyle(.borderedProminent)

                        Button("Open System Settings") {
                            openCalendarPrivacySettings()
                        }
                        .buttonStyle(.bordered)

                        Button(isResettingCalendarPermission ? "Resetting…" : "Reset Permission") {
                            resetCalendarPermission()
                        }
                        .disabled(isResettingCalendarPermission)
                        .buttonStyle(.bordered)
                    }
                } else {
                    if !GoogleAuthConfig.isConfigured {
                        Text("Google OAuth is not configured. Configure credentials in GoogleAuth.swift.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if googleAuth.isAuthenticated {
                        if let email = googleAuth.userEmail {
                            Text("Signed in as \(email)")
                                .foregroundColor(.secondary)
                        } else {
                            Text("Google Calendar connected")
                                .foregroundColor(.secondary)
                        }
                        Button("Reset Permission (Sign Out)") {
                            googleAuth.signOut()
                            featureCalendarEnabled = false
                            notifyPreferencesChanged()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Grant Permission (Sign in with Google)") {
                            Task { await signInWithGoogle() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Divider()

                permissionStatusRow(
                    granted: notificationsAuthorized,
                    grantedText: "Notification permission granted",
                    missingText: "Notification permission required for reminders"
                )

                HStack(spacing: 8) {
                    Button("Grant Notification Permission") {
                        requestNotificationAccess()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open Notification Settings") {
                        openNotificationSettings()
                    }
                    .buttonStyle(.bordered)

                    Button(isResettingNotificationPermission ? "Resetting…" : "Reset Permission") {
                        resetNotificationPermission()
                    }
                    .disabled(isResettingNotificationPermission)
                    .buttonStyle(.bordered)
                }
            }

            Section("Calendar Selection") {
                if calendarProvider == CalendarProvider.google.rawValue {
                    Text("Google provider selected. Calendar account setup is managed by your Google sign-in.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    switch calendarAuthStatus {
                    case .notDetermined:
                        Text("Grant calendar permission to select calendars.")
                            .foregroundColor(.secondary)
                    case .fullAccess:
                        if meetingManager.calendars.isEmpty {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Loading calendars…").foregroundColor(.secondary)
                            }
                        } else {
                            calendarList
                        }
                    case .restricted, .denied, .writeOnly:
                        Text("Calendar permission is missing.")
                            .foregroundColor(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .disabled(!canEditCalendarConfig)

            Section("Meeting Display") {
                VStack(alignment: .leading) {
                    Text("Meeting title max length:")
                    HStack {
                        Slider(value: Binding(
                            get: { Double(titleMaxLength) },
                            set: { titleMaxLength = Int($0) }
                        ), in: 10...50, step: 1)
                        Text("\(titleMaxLength) characters")
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                    }
                }

                Picker("Event time format:", selection: $timeFormat) {
                    Text("Relative (\"in 12m\" / \"now (25m left)\")").tag("relative")
                    Text("Absolute (\"10:00\")").tag("absolute")
                }
                .pickerStyle(.radioGroup)

                Toggle("Show tomorrow's events", isOn: $showTomorrowEvents)
                Toggle("Show declined events (dimmed)", isOn: $showDeclinedEvents)
            }
            .disabled(!canEditCalendarConfig)

            Section("Notifications") {
                Toggle("Enable meeting notifications", isOn: Binding(
                    get: { meetingNotificationsEnabled },
                    set: { setMeetingNotificationsEnabled($0) }
                ))
                .disabled(!featureCalendarEnabled)

                Picker("Notify before event:", selection: $notificationMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                }
                .disabled(!featureCalendarEnabled || !meetingNotificationsEnabled)

                Toggle("End-of-event notification", isOn: $endOfEventNotification)
                    .disabled(!featureCalendarEnabled || !meetingNotificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        .onAppear(perform: refreshAuthStatus)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            refreshAuthStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAuthStatus()
        }
        .onChange(of: calendarProvider) { _, _ in
            if featureCalendarEnabled && !canEnableCalendarFeature {
                featureCalendarEnabled = false
            }
            notifyPreferencesChanged()
            refreshAuthStatus()
        }
    }

    @ViewBuilder
    private func permissionStatusRow(granted: Bool, grantedText: String, missingText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
            Text(granted ? grantedText : missingText)
        }
    }

    private var calendarList: some View {
        let grouped = Dictionary(grouping: meetingManager.calendars, by: { $0.source })
        return ForEach(grouped.keys.sorted(), id: \.self) { source in
            Section(source) {
                ForEach(grouped[source] ?? [], id: \.id) { calendar in
                    Toggle(isOn: Binding(
                        get: { selectedCalendarIDs.contains(calendar.id) },
                        set: { isSelected in
                            if isSelected {
                                selectedCalendarIDs.insert(calendar.id)
                            } else {
                                selectedCalendarIDs.remove(calendar.id)
                            }
                            saveSelectedCalendars()
                            Task { await meetingManager.refreshEvents() }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: calendar.color) ?? .accentColor)
                                .frame(width: 12, height: 12)
                            Text(calendar.title)
                        }
                    }
                }
            }
        }
    }

    private func refreshAuthStatus() {
        calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
        if hasMacCalendarPermission {
            if meetingManager.calendars.isEmpty {
                Task { await meetingManager.loadCalendars() }
            }
            loadSelectedCalendars()
        }

        // UNUserNotificationCenter.current() requires a valid bundle proxy.
        // Guard against crashes when running as a raw SPM binary.
        guard Bundle.main.bundleIdentifier != nil else {
            AppLogger.warning("No bundle identifier — skipping notification permission check (running outside .app bundle?)", category: "Permissions")
            notificationsAuthorized = false
            meetingNotificationsEnabled = false
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                notificationsAuthorized = isNotificationStatusGranted(settings.authorizationStatus)
                if !notificationsAuthorized {
                    meetingNotificationsEnabled = false
                }
                AppLogger.info("Notification auth status: \(settings.authorizationStatus.rawValue) — granted: \(notificationsAuthorized)", category: "Permissions")
            }
        }
    }

    private func setCalendarFeatureEnabled(_ enabled: Bool) {
        guard enabled else {
            featureCalendarEnabled = false
            notifyPreferencesChanged()
            return
        }

        if canEnableCalendarFeature {
            featureCalendarEnabled = true
            notifyPreferencesChanged()
            return
        }

        if calendarProvider == CalendarProvider.eventKit.rawValue {
            grantCalendarAccess()
        } else {
            Task { await signInWithGoogle() }
        }
    }

    private func setMeetingNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            meetingNotificationsEnabled = false
            notifyPreferencesChanged()
            return
        }
        guard notificationsAuthorized else {
            requestNotificationAccess()
            return
        }
        meetingNotificationsEnabled = true
        notifyPreferencesChanged()
    }

    private func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func grantCalendarAccess() {
        DispatchQueue.main.async {
            Task { await requestCalendarAccess() }
        }
    }

    private func requestCalendarAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            let granted = try await meetingManager.requestAccess()
            calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                AppLogger.info("Calendar access granted", category: "Permissions")
                await meetingManager.loadCalendars()
                loadSelectedCalendars()
                featureCalendarEnabled = true
                notifyPreferencesChanged()
            } else {
                AppLogger.warning("Calendar access denied by user", category: "Permissions")
            }
        } catch {
            AppLogger.error("Calendar access request failed: \(error.localizedDescription)", category: "Permissions")
            calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
            featureCalendarEnabled = false
        }
    }

    private func requestNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else {
            AppLogger.warning("Cannot request notification access — no bundle identifier (running outside .app bundle?)", category: "Permissions")
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    notificationsAuthorized = true
                    meetingNotificationsEnabled = true
                    notifyPreferencesChanged()
                    AppLogger.info("Notification access already granted", category: "Permissions")
                }
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    Task { @MainActor in
                        notificationsAuthorized = granted
                        meetingNotificationsEnabled = granted
                        notifyPreferencesChanged()
                        AppLogger.info("Notification access request result: \(granted ? "granted" : "denied")", category: "Permissions")
                    }
                }
            case .denied:
                Task { @MainActor in
                    notificationsAuthorized = false
                    meetingNotificationsEnabled = false
                    AppLogger.warning("Notification access denied — opening System Settings", category: "Permissions")
                    openNotificationSettings()
                }
            @unknown default:
                Task { @MainActor in
                    notificationsAuthorized = false
                    meetingNotificationsEnabled = false
                    AppLogger.warning("Unknown notification authorization status: \(settings.authorizationStatus.rawValue)", category: "Permissions")
                }
            }
        }
    }

    private func signInWithGoogle() async {
        do {
            try await googleAuth.signIn()
            if googleAuth.isAuthenticated {
                AppLogger.info("Google sign-in successful", category: "Permissions")
                featureCalendarEnabled = true
                notifyPreferencesChanged()
            }
        } catch {
            AppLogger.error("Google sign-in failed: \(error.localizedDescription)", category: "Permissions")
            featureCalendarEnabled = false
        }
    }

    private func resetCalendarPermission() {
        guard !isResettingCalendarPermission else { return }
        isResettingCalendarPermission = true
        featureCalendarEnabled = false
        notifyPreferencesChanged()

        AppLogger.info("Resetting Calendar permission via tccutil", category: "Permissions")

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "Calendar", Constants.bundleIdentifier]
            do {
                try task.run()
                task.waitUntilExit()
                AppLogger.info("Calendar permission reset completed (exit code: \(task.terminationStatus))", category: "Permissions")
            } catch {
                AppLogger.error("Failed to run tccutil for Calendar reset: \(error.localizedDescription)", category: "Permissions")
            }
            DispatchQueue.main.async {
                isResettingCalendarPermission = false
                refreshAuthStatus()
            }
        }
    }

    private func resetNotificationPermission() {
        guard !isResettingNotificationPermission else { return }
        isResettingNotificationPermission = true
        meetingNotificationsEnabled = false
        notifyPreferencesChanged()

        AppLogger.info("Resetting Notifications permission via tccutil", category: "Permissions")

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "Notifications", Constants.bundleIdentifier]
            do {
                try task.run()
                task.waitUntilExit()
                AppLogger.info("Notifications permission reset completed (exit code: \(task.terminationStatus))", category: "Permissions")
            } catch {
                AppLogger.error("Failed to run tccutil for Notifications reset: \(error.localizedDescription)", category: "Permissions")
            }
            DispatchQueue.main.async {
                isResettingNotificationPermission = false
                refreshAuthStatus()
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

    private func loadSelectedCalendars() {
        guard let data = UserDefaults.standard.data(forKey: Constants.Defaults.selectedCalendars),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            selectedCalendarIDs = Set(meetingManager.calendars.map { $0.id })
            return
        }
        selectedCalendarIDs = Set(ids)
    }

    private func saveSelectedCalendars() {
        let ids = Array(selectedCalendarIDs)
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: Constants.Defaults.selectedCalendars)
        }
    }

    private func notifyPreferencesChanged() {
        NotificationCenter.default.post(name: .businessBarPreferencesDidChange, object: nil)
    }
}

// MARK: - CalendarProvider

enum CalendarProvider: String, CaseIterable {
    case eventKit = "EventKit"
    case google   = "Google"
}

// MARK: - Color+Hex (shared helper)

extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                   .replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        self.init(
            red:   Double((rgb & 0xFF0000) >> 16) / 255,
            green: Double((rgb & 0x00FF00) >>  8) / 255,
            blue:  Double( rgb & 0x0000FF       ) / 255
        )
    }
}
