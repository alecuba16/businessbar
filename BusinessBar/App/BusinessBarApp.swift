import AppKit
import SwiftUI

@main
struct BusinessBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            PreferencesView(
                badgeManager: appDelegate.preferencesBadgeManager,
                meetingManager: appDelegate.preferencesMeetingManager,
                googleAuth: appDelegate.googleAuth
            )
            .environmentObject(appDelegate.updaterViewModel)
        }
    }
}
