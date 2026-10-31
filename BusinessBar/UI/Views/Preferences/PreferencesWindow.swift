import AppKit
import BusinessBarCore
import os.log
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    /// Creates the preferences window.  Throws if the SwiftUI hosting view
    /// cannot be constructed (e.g. corrupted @Published state that triggers
    /// an assertion during body evaluation).
    convenience init(
        updaterViewModel: UpdaterViewModel,
        badgeManager: BadgeManager,
        meetingManager: MeetingManager,
        googleAuth: GoogleAuth,
        initialTab: PreferencesView.PreferenceTab? = nil
    ) {
        AppLogger.info("PreferencesWindowController init — building window", category: "Preferences")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.center()
        window.title = "BusinessBar Preferences"
        window.isReleasedWhenClosed = false

        let rootView = PreferencesView(
            badgeManager: badgeManager,
            meetingManager: meetingManager,
            googleAuth: googleAuth,
            initialTab: initialTab
        )
        .environmentObject(updaterViewModel)

        window.contentView = NSHostingView(rootView: rootView)

        self.init(window: window)

        AppLogger.info("PreferencesWindowController init — window created successfully", category: "Preferences")
    }

    func show() {
        guard let window else {
            AppLogger.fatal("PreferencesWindowController.show() — window is nil", category: "Preferences")
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppLogger.info("Preferences window shown and activated", category: "Preferences")
    }
}

// MARK: - PreferencesView

struct PreferencesView: View {
    struct TabContent {
        var general: () -> GeneralTab = { GeneralTab() }
        var calendars: (MeetingManager, GoogleAuth) -> CalendarsTab = { CalendarsTab(meetingManager: $0, googleAuth: $1) }
        var noSleep: () -> NoSleepTab = { NoSleepTab() }
        var companion: () -> CompanionTab = { CompanionTab() }
    }

    @ObservedObject var badgeManager: BadgeManager
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var googleAuth: GoogleAuth
    /// Tab selected at window creation; cross-window callers (the chat
    /// panel's setup hint) pass the section that explains what to do.
    @State private var selectedTab: PreferenceTab
    private let tabContent: TabContent

    init(badgeManager: BadgeManager, meetingManager: MeetingManager, googleAuth: GoogleAuth, initialTab: PreferenceTab? = nil, tabContent: TabContent = TabContent()) {
        self.badgeManager = badgeManager
        self.meetingManager = meetingManager
        self.googleAuth = googleAuth
        self.tabContent = tabContent
        _selectedTab = State(initialValue: initialTab ?? .general)
    }

    enum PreferenceTab: String, CaseIterable {
        case general    = "General"
        case calendars  = "Calendars"
        case badges     = "Badges"
        case noSleep    = "NoSleep"
        case appearance = "Appearance"
        case companion  = "Companion"

        var icon: String {
            switch self {
            case .general:    return "gearshape"
            case .calendars:  return "calendar"
            case .badges:     return "app.badge"
            case .noSleep:    return "cup.and.heat.waves"
            case .appearance: return "paintbrush"
            case .companion:  return "bubble.left.and.text.bubble.right"
            }
        }
    }

    var body: some View {
        SettingsSavedHost {
            NavigationSplitView {
                List(PreferenceTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180)
            } detail: {
                switch selectedTab {
                case .general:     tabContent.general()
                case .calendars:   tabContent.calendars(meetingManager, googleAuth)
                case .badges:      BadgesTab(badgeManager: badgeManager)
                case .noSleep:     tabContent.noSleep()
                case .appearance:  AppearanceTab()
                case .companion:   tabContent.companion()
                }
            }
            .frame(minWidth: 800, minHeight: 600)
        }
    }
}
