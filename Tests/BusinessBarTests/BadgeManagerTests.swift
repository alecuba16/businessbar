import XCTest
@testable import BusinessBarCore

@MainActor
final class BadgeManagerTests: XCTestCase {
    private lazy var defaults: UserDefaults = {
        let name = "com.businessbar.tests.badges.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return value
    }()

    private func makeManager() -> BadgeManager {
        BadgeManager(defaults: defaults, notifications: NotificationCenter(), trust: { false },
                     monitor: StubMonitor(),
                     schedule: { interval, _ in Timer(timeInterval: interval, repeats: true) { _ in } },
                     requestPermission: {}, openSettings: { _ in })
    }

    private final class StubMonitor: BadgeMonitoring {
        var onBadgeUpdate: ((String, Int) -> Void)?
        func startMonitoring(apps: [MonitoredApp]) {}
        func stopMonitoring() {}
        func updateAppElements(for apps: [MonitoredApp]) {}
        func restartPollTimer() {}
    }

    func test_initialStateIsEmpty() {
        let manager = makeManager()
        XCTAssertTrue(manager.monitoredApps.isEmpty)
        XCTAssertTrue(manager.badges.isEmpty)
    }

    func test_addAppAppendsToMonitoredApps() {
        let manager = makeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        XCTAssertEqual(manager.monitoredApps.count, 1)
        XCTAssertEqual(manager.monitoredApps.first?.bundleIdentifier, "com.example.app")
    }

    func test_addingSameBundleIDTwiceDoesNotDuplicate() {
        let manager = makeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        manager.addApp(app)
        XCTAssertEqual(manager.monitoredApps.count, 1)
    }

    func test_removeAppRemovesFromMonitoredApps() {
        let manager = makeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        manager.removeApp("com.example.app")
        XCTAssertTrue(manager.monitoredApps.isEmpty)
    }

    func test_removeAppAlsoRemovesBadge() {
        let manager = makeManager()
        let app = MonitoredApp(bundleIdentifier: "com.example.app", displayName: "Example App")
        manager.addApp(app)
        manager.removeApp("com.example.app")
        XCTAssertNil(manager.badges["com.example.app"])
    }
}
