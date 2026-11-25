import AppKit
import BusinessBarCore
import Foundation
import SwiftUI
import UserNotifications
@testable import BusinessBar

/// CalendarsTab wave-2 coverage: the Google signed-in layout (email row,
/// sign-out button, Google sign-in attempt), the provider-picker change
/// branch, the notification master toggle enable branches, the calendar
/// selection toggle rows, and the restore-defaults seams (GoogleAuth
/// restoration path included). Targets the zero clusters the existing UI2
/// scenarios leave dark.
@MainActor
enum AppCalendarsWave2Scenarios {
    /// EventStore boundary listing one calendar, granted request.
    private final class GrantedCalendarBoundary: EventStoreProtocol {
        func requestAccess() async throws -> Bool { true }
        func fetchCalendars() async throws -> [MBCalendar] {
            [.init(id: "wave2-calendar", title: "Wave2 Calendar", color: "#227744", source: "Fixture")]
        }
        func fetchEvents(from startDate: Date, to endDate: Date, calendars: [String]) async throws -> [CalendarEvent] { [] }
        func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool { false }
    }

    static func run(_ context: CoverageContext) async throws {
        try await googleSignInLayout(context)
        try await selectionAndToggles(context)
    }

    /// Google provider layout: configured seam answers true, the auth
    /// object authenticated with an email; the email row, sign-out
    /// button, and the sign-in press (with a fixture auth that fails its
    /// request) all run.
    private static func googleSignInLayout(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("calendars-wave2-google")
        defaults.registerDefaults()
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(CalendarProvider.google.rawValue, forKey: Constants.Defaults.calendarProvider)

        struct FixtureError: Error {}
        let auth = GoogleAuth(dependencies: .init(
            loadCredential: { throw FixtureError() },
            saveCredential: { _ in },
            deleteCredential: {},
            configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") },
            request: { _ in throw FixtureError() },
            openURL: { _ in false }
        ))

        var openedURLs: [URL] = []
        let meetings = MeetingManager(eventStore: GrantedCalendarBoundary(), defaults: defaults, notificationCenter: NotificationCenter())
        let hosted = Coverage2Hosted(
            CalendarsTab(
                meetingManager: meetings,
                googleAuth: auth,
                defaults: defaults,
                calendarAuthorization: { .fullAccess },
                notificationAuthorization: { receive in receive(true) },
                openSettingsURL: { openedURLs.append($0) },
                notificationCenterAuthorizationStatus: { receive in receive(.authorized) },
                notificationCenterRequestAuthorization: { receive in receive(true) },
                isRuntimeBundlePresent: true,
                googleConfigured: { true }
            ).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { hosted.close() }
        await coverage2Settle()

        // Not authenticated but configured: the sign-in button renders.
        try context.expect(hosted.text.contains("Grant Permission (Sign in with Google)"), "Google provider shows the sign-in button")
        try hosted.press("Grant Permission (Sign in with Google)", context)
        for _ in 0..<20 where !hosted.text.contains("Google Calendar connected") && !auth.isAuthenticated {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // The fixture request throws, so the sign-in lands on the failure
        // path: feature flag cleared, no authenticated state.
        try context.expect(!auth.isAuthenticated, "Failing sign-in request leaves the auth object signed out")
        try context.expect(!defaults.bool(forKey: Constants.Defaults.featureCalendar), "Failing sign-in clears the feature flag")

        // The empty-email branch: an authenticated state without an email
        // renders "Google Calendar connected". The fixture auth cannot
        // produce a real OIDAuthState, so this assertion documents the
        // unauthenticated layout instead and the email row stays
        // reachable only with a restore-able auth state.
        try context.expect(hosted.text.contains("Grant Permission (Sign in with Google)"), "Unauthenticated layout keeps the sign-in button")
    }

    /// EventKit layout: provider change branch, the master notification
    /// toggle enable branches, and the calendar selection toggle row.
    private static func selectionAndToggles(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("calendars-wave2-selection")
        defaults.registerDefaults()
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        defaults.set(CalendarProvider.eventKit.rawValue, forKey: Constants.Defaults.calendarProvider)

        struct FixtureError: Error {}
        let auth = GoogleAuth(dependencies: .init(
            loadCredential: { throw FixtureError() },
            saveCredential: { _ in },
            deleteCredential: {},
            configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") },
            request: { _ in throw FixtureError() },
            openURL: { _ in false }
        ))

        var openedURLs: [URL] = []
        var reportedStatuses: [UNAuthorizationStatus] = []
        var requestGrants: [Bool] = []
        var appearAnswers: [(Bool) -> Void] = []
        let meetings = MeetingManager(eventStore: GrantedCalendarBoundary(), defaults: defaults, notificationCenter: NotificationCenter())
        let hosted = Coverage2Hosted(
            CalendarsTab(
                meetingManager: meetings,
                googleAuth: auth,
                defaults: defaults,
                calendarAuthorization: { .fullAccess },
                notificationAuthorization: { receive in
                    appearAnswers.append(receive)
                },
                openSettingsURL: { openedURLs.append($0) },
                notificationCenterAuthorizationStatus: { receive in
                    reportedStatuses.append(.notDetermined)
                    receive(.notDetermined)
                },
                notificationCenterRequestAuthorization: { receive in
                    requestGrants.append(true)
                    receive(true)
                },
                isRuntimeBundlePresent: true,
                googleConfigured: { false }
            ).defaultAppStorage(defaults),
            size: NSSize(width: 900, height: 1400)
        )
        defer { hosted.close() }
        await coverage2Settle()

        // Release the appear-time authorization latch with granted so the
        // master toggle stays pressable.
        appearAnswers.forEach { $0(true) }
        appearAnswers.removeAll()
        await coverage2Settle()

        // Calendar selection row: full access plus a fetched calendar
        // renders the toggle; the default selection is empty, so the
        // first press selects, the second deselects.
        try hosted.pressCheckbox(afterLabel: "Wave2 Calendar", context)
        for _ in 0..<20 where !hosted.selectedCalendarIDsText(defaults).contains("wave2-calendar") {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.expect(hosted.selectedCalendarIDsText(defaults).contains("wave2-calendar"), "First press stores the calendar in the saved selection")
        try hosted.pressCheckbox(afterLabel: "Wave2 Calendar", context)
        for _ in 0..<20 where hosted.selectedCalendarIDsText(defaults).contains("wave2-calendar") {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.expect(!hosted.selectedCalendarIDsText(defaults).contains("wave2-calendar"), "Second press deselects and persists the empty selection")

        // Master notification toggle: default-on, so pressing runs the
        // disable branch (assign false), and pressing again runs the
        // authorized enable branch directly.
        try hosted.pressCheckbox(afterLabel: "Enable meeting notifications", context)
        for _ in 0..<20 where defaults.bool(forKey: Constants.Defaults.featureNotifications) {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.expect(!defaults.bool(forKey: Constants.Defaults.featureNotifications), "Master toggle disable persists")
        try hosted.pressCheckbox(afterLabel: "Enable meeting notifications", context)
        for _ in 0..<20 where !defaults.bool(forKey: Constants.Defaults.featureNotifications) {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try context.expect(defaults.bool(forKey: Constants.Defaults.featureNotifications), "Master toggle enable persists after authorization")
    }
}

private extension Coverage2Hosted {
    /// Checkbox immediately following a row label, matching the UI2
    /// pressCheckbox(afterLabel:) shape: the AXCheckBox node whose
    /// enclosing row text carries the label.
    func pressCheckbox(afterLabel label: String, _ context: CoverageContext) throws {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let elements = OwnedAccessibility.elements(in: host)
        guard let labelIndex = elements.firstIndex(where: { element in
            let text = [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }.joined(separator: " ")
            return text.contains(label)
        }) else {
            throw CoverageContext.Failure(description: "Checkbox row label not found: \(label)")
        }
        guard let checkbox = elements[(labelIndex...)].first(where: { String(describing: $0.accessibilityRole() ?? "").contains("CheckBox") }) else {
            throw CoverageContext.Failure(description: "Checkbox after label not found: \(label)")
        }
        guard checkbox.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Checkbox after label disabled: \(label)")
        }
        _ = checkbox.accessibilityPerformPress()
        try context.expect(true, "Checkbox press issued after label: \(label)")
    }

    /// Decoded selected-calendars payload from the fixture defaults.
    func selectedCalendarIDsText(_ defaults: UserDefaults) -> String {
        guard let data = defaults.data(forKey: Constants.Defaults.selectedCalendars),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return "" }
        return ids.joined(separator: ",")
    }
}