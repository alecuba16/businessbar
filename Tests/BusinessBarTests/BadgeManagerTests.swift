import XCTest
@testable import BusinessBarCore

@MainActor
final class BadgeManagerTests: XCTestCase {

    func test_initialStateIsEmpty() {
        // Clear any persisted apps from a previous run before testing initial state
        UserDefaults.standard.removeObject(forKey: Constants.Defaults.monitoredApps)
        let manager = BadgeManager()
        XCTAssertTrue(manager.monitoredApps.isEmpty)
        XCTAssertTrue(manager.badges.isEmpty)
    }

    func test_addAppAppendsToMonitoredApps() {
        let manager = BadgeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        XCTAssertEqual(manager.monitoredApps.count, 1)
        XCTAssertEqual(manager.monitoredApps.first?.bundleIdentifier, "com.example.app")
    }

    func test_addingSameBundleIDTwiceDoesNotDuplicate() {
        let manager = BadgeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        manager.addApp(app)
        XCTAssertEqual(manager.monitoredApps.count, 1)
    }

    func test_removeAppRemovesFromMonitoredApps() {
        let manager = BadgeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        manager.removeApp("com.example.app")
        XCTAssertTrue(manager.monitoredApps.isEmpty)
    }

    func test_removeAppAlsoRemovesBadge() {
        let manager = BadgeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        manager.removeApp("com.example.app")
        XCTAssertNil(manager.badges["com.example.app"])
    }
}
