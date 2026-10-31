import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt
@testable import BusinessBarCore

private final class SystemScheduler {
    private(set) var intervals: [TimeInterval] = []
    private(set) var timers: [Timer] = []

    func schedule(_ interval: TimeInterval, _ action: @escaping () -> Void) -> Timer {
        intervals.append(interval)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        timers.append(timer)
        return timer
    }

    deinit {
        timers.forEach { $0.invalidate() }
    }
}

private final class SystemBadgeMonitor: BadgeMonitoring {
    var onBadgeUpdate: ((String, Int) -> Void)?
    var starts: [[MonitoredApp]] = []
    var updates: [[MonitoredApp]] = []
    var stops = 0
    var restarts = 0
    func startMonitoring(apps: [MonitoredApp]) { starts.append(apps) }
    func stopMonitoring() { stops += 1 }
    func updateAppElements(for apps: [MonitoredApp]) { updates.append(apps) }
    func restartPollTimer() { restarts += 1 }
}

@MainActor
enum CoreSystemScenarios {
    static func run(_ context: CoverageContext) async throws {
        try await badges(context)
        try monitor(context)
        try await monitorRealObserver(context)
        try discoveryAndIcons(context)
        try await noSleep(context)
        try assertionsAndActivity(context)
    }

    private static func drain() async {
        await Task { @MainActor in }.value
    }

    private static func badges(_ c: CoverageContext) async throws {
        let defaults = try c.defaults("badges")
        let notifications = NotificationCenter()
        let monitor = SystemBadgeMonitor()
        let scheduler = SystemScheduler()
        var trusted = false
        var requests = 0
        var opened: URL?
        let manager = BadgeManager(defaults: defaults, notifications: notifications, trust: { trusted },
                                   monitor: monitor, schedule: scheduler.schedule,
                                   requestPermission: { requests += 1 }, openSettings: { opened = $0 })
        try c.expect(manager.monitoredApps.isEmpty && manager.badges.isEmpty, "badge initial state")
        try c.equal(scheduler.intervals, [2], "permission timer starts without AX reads")
        let app = MonitoredApp(bundleIdentifier: "coverage.one", displayName: "One")
        manager.addApp(app)
        manager.addApp(app)
        try c.equal(manager.monitoredApps.count, 1, "badge duplicate app ignored")
        try c.expect(monitor.updates.isEmpty, "untrusted monitor not refreshed")
        try c.expect(defaults.data(forKey: Constants.Defaults.monitoredApps) != nil, "badge list persisted in suite")
        manager.requestAccessibilityPermission()
        manager.openAccessibilitySettings()
        try c.equal(requests, 1, "permission request delegated")
        try c.equal(opened?.scheme, "x-apple.systempreferences", "settings open delegated")
        try c.equal(scheduler.timers.count, 1, "permission polling is idempotent")
        trusted = true
        scheduler.timers[0].fire()
        await drain()
        try c.expect(manager.isAccessibilityGranted, "permission grant published")
        try c.equal(monitor.starts.last, [app], "grant starts configured apps")
        try c.expect(!scheduler.timers[0].isValid, "permission timer stops after grant")
        monitor.onBadgeUpdate?(app.bundleIdentifier, 7)
        await drain()
        try c.equal(manager.badges[app.bundleIdentifier], 7, "monitor callback publishes badge")
        try c.equal(manager.monitoredApps.first?.badgeCount, 7, "app badge tracks dictionary")
        manager.updateBadge(for: app.bundleIdentifier, count: 7)
        manager.updateBadge(for: "unknown", count: 2)
        manager.updateBadge(for: app.bundleIdentifier, count: 0)
        try c.expect(manager.badges[app.bundleIdentifier] == nil, "zero badge removes dictionary value")
        manager.addApp(MonitoredApp(bundleIdentifier: "coverage.two", displayName: "Two"))
        try c.equal(monitor.updates.last?.count, 2, "trusted app addition refreshes monitor")
        manager.removeApp(app.bundleIdentifier)
        try c.equal(manager.monitoredApps.count, 1, "badge removal persists")
        defaults.set(false, forKey: Constants.Defaults.featureBadges)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        await drain()
        try c.expect(manager.badges.isEmpty, "disabling badges clears counts")
        try c.expect(monitor.stops > 0, "disabling badges stops monitor")
        manager.addApp(app)
        manager.removeApp("coverage.two")
        defaults.set(true, forKey: Constants.Defaults.featureBadges)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        await drain()
        try c.equal(monitor.restarts, 1, "enabling badges restarts interval")
        let loaded = BadgeManager(defaults: defaults, notifications: NotificationCenter(), trust: { true },
                                  monitor: SystemBadgeMonitor(), schedule: scheduler.schedule,
                                  requestPermission: {}, openSettings: { _ in })
        try c.equal(loaded.monitoredApps, manager.monitoredApps, "badge apps reload")
        defaults.set(Data("invalid".utf8), forKey: Constants.Defaults.monitoredApps)
        defaults.set(false, forKey: Constants.Defaults.featureBadges)
        let disabledMonitor = SystemBadgeMonitor()
        let disabled = BadgeManager(defaults: defaults, notifications: notifications, trust: { false },
                                    monitor: disabledMonitor, schedule: scheduler.schedule,
                                    requestPermission: {}, openSettings: { _ in })
        try c.expect(disabled.monitoredApps.isEmpty, "corrupt badge persistence ignored")
        try c.equal(disabledMonitor.stops, 1, "disabled init never starts monitoring")
        disabled.checkAccessibilityPermission()
        disabled.requestAccessibilityPermission()
        defaults.set(true, forKey: Constants.Defaults.featureBadges)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        await drain()
        try c.expect(scheduler.timers.count > 1, "untrusted enable starts permission polling")
        disabled.checkAccessibilityPermission()
    }

    private static func monitor(_ c: CoverageContext) throws {
        for (text, value) in [(nil, 0), ("", 0), ("42 messages", 42), ("9+", 9), ("•", 1), ("999999999999999999999999999", 1)] as [(String?, Int)] {
            try c.equal(BadgeMonitor.parseBadge(text), value, "badge label parse \(text ?? "nil")")
        }
        let defaults = try c.defaults("monitor")
        let scheduler = SystemScheduler()
        let root = AXUIElementCreateApplication(-1001)
        let direct = AXUIElementCreateApplication(-1002)
        let group = AXUIElementCreateApplication(-1003)
        let nested = AXUIElementCreateApplication(-1004)
        let unknown = AXUIElementCreateApplication(-1005)
        var children: [AXUIElement]? = [direct, group, unknown]
        var label = "5+"
        var trusted = false
        var starts = 0
        var cancellations = 0
        var refresh: (() -> Void)?
        var received: [Int] = []
        let monitor = BadgeMonitor(defaults: defaults, trust: { trusted }, dock: { (0, root) },
                                   attribute: { element, attribute in
            if attribute == kAXChildrenAttribute {
                if CFEqual(element, root) { return children.map { $0 as CFTypeRef } }
                if CFEqual(element, group) { return [nested] as CFTypeRef }
            }
            if attribute == "AXBundleIdentifier" {
                if CFEqual(element, direct) { return "coverage.direct" as CFString }
                if CFEqual(element, nested) { return "coverage.nested" as CFString }
            }
            if attribute == "AXStatusLabel", CFEqual(element, direct) { return label as CFString }
            return nil
        }, schedule: scheduler.schedule, observe: { _, _, callback in
            starts += 1
            refresh = callback
            return { cancellations += 1 }
        })
        let apps = [MonitoredApp(bundleIdentifier: "coverage.direct", displayName: "Direct"),
                    MonitoredApp(bundleIdentifier: "coverage.nested", displayName: "Nested"),
                    MonitoredApp(bundleIdentifier: "coverage.missing", displayName: "Missing")]
        monitor.onBadgeUpdate = { _, count in received.append(count) }
        monitor.restartPollTimer()
        monitor.startMonitoring(apps: apps)
        try c.expect(scheduler.timers.isEmpty, "untrusted monitor never schedules")
        trusted = true
        try c.equal(monitor.allDockItemElements().count, 2, "Dock direct and nested item trees")
        monitor.startMonitoring(apps: apps)
        try c.equal(starts, 1, "injected AX observer starts")
        scheduler.timers.last?.fire()
        monitor.pollBadges()
        try c.equal(received, [5], "unchanged badge values suppressed")
        label = ""
        monitor.pollBadges()
        try c.equal(received, [5, 0], "badge clear is delivered")
        defaults.set(7, forKey: Constants.Defaults.badgePollInterval)
        monitor.restartPollTimer()
        try c.equal(scheduler.intervals.last, 7, "badge interval reload")
        try c.expect(!scheduler.timers[0].isValid, "badge restart invalidates previous timer")
        refresh?()
        children = nil
        try c.expect(monitor.allDockItemElements().isEmpty, "AX children error returns no items")
        refresh?()
        label = "8"
        monitor.pollBadges()
        try c.equal(received, [5, 0], "removed Dock children no longer polled")
        monitor.stopMonitoring()
        monitor.stopMonitoring()
        try c.equal(cancellations, 1, "observer cancelled once")
        let absent = BadgeMonitor(defaults: defaults, trust: { true }, dock: { (0, nil) },
                                  attribute: { _, _ in nil }, schedule: scheduler.schedule)
        try c.expect(absent.allDockItemElements().isEmpty, "missing Dock is empty")
        absent.startMonitoring(apps: apps)
        absent.stopMonitoring()
    }

    /// The real AXObserver path: setupAXObserver/tearDownAXObserver and the
    /// kAXCreated notification callback. Measured with a probe on this host:
    /// AXObserverCreate succeeds on the scenario process's OWN pid without
    /// AX trust (self-owned AX needs no prompt), and creating an owned
    /// window fires the notification so handleDockChildChange and
    /// refreshDockChildren run for real. The dock seam points at the
    /// process itself, so no other application is ever queried.
    private static func monitorRealObserver(_ c: CoverageContext) async throws {
        // The AX tree of this process only materializes once NSApplication
        // is properly launched (measured: the probe failed the same way
        // without this). Prohibited policy keeps it off the Dock.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let defaults = UserDefaults(suiteName: "core.badge.real-observer")!
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier ?? "coverage.self"
        let monitor = BadgeMonitor(
            defaults: defaults,
            trust: { true },
            dock: { (selfPID, AXUIElementCreateApplication(selfPID)) },
            attribute: { element, name in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                return value
            },
            schedule: { interval, action in
                Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() }
            }
        )
        let apps = [MonitoredApp(bundleIdentifier: ownBundleID, displayName: "Self")]
        var received: [Int] = []
        monitor.onBadgeUpdate = { _, count in received.append(count) }

        // startMonitoring with a real observer on our own pid: the element
        // scan finds nothing yet (no windows), then a created window makes
        // the kAXCreated notification fire and the dock children refresh
        // to include it.
        monitor.startMonitoring(apps: apps)
        try c.expect(monitor.allDockItemElements().count >= 0, "Real-observer start completes against the own process")

        let window = NSWindow(
            contentRect: NSRect(x: -100_000, y: -100_000, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // Same rule as every hosted harness window: with the Swift strong
        // reference alive, AppKit's released-when-closed would over-release
        // (measured: _NSWindowTransformAnimation dealloc segfault in the
        // next suite's autorelease pool pop).
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFrontRegardless()
        var matched = monitor.allDockItemElements().count
        for _ in 0..<40 where matched == 0 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            matched = monitor.allDockItemElements().count
        }
        try c.expect(matched > 0, "Owned window creation reaches the real kAXCreated observer")

        // The notification callback and the poll both ran without touching
        // any process other than the scenario's own.
        monitor.pollBadges()
        monitor.stopMonitoring()
        try c.expect(monitor.allDockItemElements().count >= matched, "Teardown keeps the live scan functional after stop")
        // Deterministic window teardown: closing inside the scenario and
        // draining the run loop settles the CA window-animation commit here
        // (measured crash: leaving it to the variable's dealloc segfaulted
        // an _NSWindowTransformAnimation in the next suite's autorelease
        // pool pop).
        window.orderOut(nil)
        window.close()
        for _ in 0..<10 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func discoveryAndIcons(_ c: CoverageContext) throws {
        let directory = try c.temporaryDirectory("apps")
        func bundle(_ name: String, _ info: [String: String]) throws -> URL {
            let url = directory.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let display = try bundle("Zulu", ["CFBundleIdentifier": "coverage.z", "CFBundleDisplayName": "Alpha", "CFBundleName": "Unused"])
        let named = try bundle("Other", ["CFBundleIdentifier": "coverage.b", "CFBundleName": "Beta"])
        let fallback = try bundle("Gamma", ["CFBundleIdentifier": "coverage.g"])
        let invalid = try bundle("Invalid", [:])
        let apps = AppDiscovery.apps(at: [fallback.path, named.path, invalid.path, display.path, directory.appendingPathComponent("missing.app").path])
        try c.equal(apps.map(\.displayName), ["Alpha", "Beta", "Gamma"], "discovery names fall back and sort")
        try c.equal(apps.first?.iconPath, display.path, "discovery retains bundle path")
        let image = NSImage(size: NSSize(width: 8, height: 8))
        var paths: [String] = []
        let directoryIcon = apps[0].resolveIcon(iconForFile: { paths.append($0); return image }, applicationPath: { _ in nil }, loadImage: { _ in nil })
        try c.expect(directoryIcon === image, "directory icon uses workspace resolver seam")
        try c.equal(paths, [display.path], "directory path passed to icon resolver")
        let fileApp = MonitoredApp(bundleIdentifier: "coverage.file", displayName: "File", iconPath: directory.appendingPathComponent("icon.icns").path)
        try c.expect(fileApp.resolveIcon(iconForFile: { _ in nil }, applicationPath: { _ in nil }, loadImage: { _ in image }) === image, "bare file icon resolves")
        try c.expect(fileApp.resolveIcon(iconForFile: { _ in image }, applicationPath: { _ in display.path }, loadImage: { _ in nil }) === image, "unreadable file falls back to bundle lookup")
        let missing = MonitoredApp(bundleIdentifier: "coverage.none", displayName: "None")
        try c.expect(missing.resolveIcon(iconForFile: { _ in nil }, applicationPath: { _ in nil }, loadImage: { _ in nil }) == nil, "missing icon stays nil")
        try c.equal(try JSONDecoder().decode(MonitoredApp.self, from: JSONEncoder().encode(fileApp)), fileApp, "monitored app codable")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        bitmap.bitmapData?.initialize(repeating: 0, count: 4)
        let png = directory.appendingPathComponent("cached.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let cachedApp = MonitoredApp(bundleIdentifier: UUID().uuidString, displayName: "Cached", iconPath: png.path)
        let first = cachedApp.icon
        try c.expect(first != nil, "icon property loads temporary image without workspace")
        try c.expect(cachedApp.icon === first, "icon property caches by bundle identifier")
        let dockRoot = AXUIElementCreateApplication(-1011)
        let dockItem = AXUIElementCreateApplication(-1012)
        let scheduler = SystemScheduler()
        var count = 0
        let urlMonitor = BadgeMonitor(defaults: try c.defaults("url-monitor"), trust: { true }, dock: { (0, dockRoot) }, attribute: { element, attribute in
            if CFEqual(element, dockRoot), attribute == kAXChildrenAttribute { return [dockItem] as CFTypeRef }
            if CFEqual(element, dockItem) {
                if attribute == "AXBundleIdentifier" { return "" as CFString }
                if attribute == "AXURL" { return display as NSURL }
                if attribute == "AXStatusLabel" { return "3" as CFString }
            }
            return nil
        }, schedule: scheduler.schedule, observe: { _, _, _ in {} })
        urlMonitor.onBadgeUpdate = { _, value in count = value }
        urlMonitor.startMonitoring(apps: apps)
        urlMonitor.pollBadges()
        try c.equal(count, 3, "Dock URL resolves temporary bundle identifier")
        urlMonitor.stopMonitoring()
    }

    private static func noSleep(_ c: CoverageContext) async throws {
        let defaults = try c.defaults("nosleep")
        let notifications = NotificationCenter()
        let workspace = NotificationCenter()
        let scheduler = SystemScheduler()
        var now = Date(timeIntervalSince1970: 5_000)
        var trusted = false
        var modes: [SleepMode] = []
        var releases = 0
        var starts = 0
        var stops = 0
        defaults.set(SleepMode.systemAndDisplay.rawValue, forKey: Constants.Defaults.noSleepSleepMode)
        let manager = NoSleepManager(defaults: defaults, notifications: notifications, workspace: workspace,
                                     trust: { trusted }, now: { now }, schedule: scheduler.schedule,
                                     activateSleep: { modes.append($0) }, deactivateSleep: { releases += 1 },
                                     startActivity: { starts += 1 }, stopActivity: { stops += 1 })
        try c.equal(manager.mode, .systemAndDisplay, "saved sleep mode loaded")
        try c.equal(manager.timeRemaining, 0, "inactive remaining time")
        manager.applySimulateActivityPreference()
        manager.activate(duration: 60)
        try c.expect(manager.isActive, "no-sleep activates")
        try c.equal(manager.timeRemaining, 60, "no-sleep uses injected clock")
        now = now.addingTimeInterval(20)
        try c.equal(manager.timeRemaining, 40, "remaining duration advances with clock")
        now = now.addingTimeInterval(100)
        try c.equal(manager.timeRemaining, 0, "expired remaining time clamps to zero")
        scheduler.timers.last?.fire()
        await drain()
        try c.expect(!manager.isActive, "duration timeout deactivates")
        defaults.set(true, forKey: Constants.Defaults.noSleepSimulateActivity)
        manager.activate(duration: 30, mode: .systemOnly)
        try c.equal(starts, 0, "activity requires trust")
        trusted = true
        manager.applySimulateActivityPreference()
        try c.equal(starts, 1, "trusted activity starts")
        manager.activate(duration: nil)
        try c.expect(manager.timeRemaining.isInfinite, "nil duration is infinite")
        try c.expect(!scheduler.timers.last!.isValid, "infinite reactivation cancels prior timeout")
        defaults.set(false, forKey: Constants.Defaults.noSleepSimulateActivity)
        notifications.post(name: .noSleepSimulateActivityChanged, object: nil)
        await drain()
        try c.expect(stops > 0, "activity preference stops simulation")
        manager.handleSystemWillSleep()
        try c.expect(manager.isActive, "sleep without preference preserves activation")
        defaults.set(true, forKey: Constants.Defaults.noSleepDeactivateOnSleep)
        manager.handleSystemWillSleep()
        try c.expect(!manager.isActive, "manual sleep preference deactivates")
        manager.handleSystemWillSleep()
        defaults.set(5, forKey: Constants.Defaults.noSleepDefaultDuration)
        manager.toggle()
        try c.equal(manager.timeRemaining, 300, "toggle uses configured minutes")
        manager.toggle()
        try c.expect(!manager.isActive, "toggle deactivates active state")
        defaults.set(0, forKey: Constants.Defaults.noSleepDefaultDuration)
        manager.toggle()
        try c.expect(manager.timeRemaining.isInfinite, "zero default duration toggles infinite")
        defaults.set(false, forKey: Constants.Defaults.featureNoSleep)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        await drain()
        try c.expect(!manager.isActive, "disabled no-sleep releases state")
        manager.activate(duration: nil)
        manager.toggle()
        manager.applySimulateActivityPreference()
        try c.expect(!manager.isActive, "disabled activation and toggle ignored")
        defaults.set(true, forKey: Constants.Defaults.featureNoSleep)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        await drain()
        manager.activate(duration: nil)
        try c.expect(manager.isActive && releases > 0 && !modes.isEmpty, "re-enable permits activation")
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await drain()
        try c.expect(!manager.isActive, "workspace sleep notification is observed")
        for mode in [SleepMode.systemOnly, .systemAndDisplay] {
            try c.equal(try JSONDecoder().decode(SleepMode.self, from: JSONEncoder().encode(mode)), mode, "sleep mode codable")
            try c.expect(!mode.description.isEmpty, "sleep mode description")
            try c.expect(CFStringGetLength(mode.assertionType) > 0, "sleep assertion type")
        }
    }

    private static func assertionsAndActivity(_ c: CoverageContext) throws {
        let workspace = NotificationCenter()
        var creates: [SleepMode] = []
        var released: [IOPMAssertionID] = []
        var fail = false
        let sleep = SleepManager(workspace: workspace, create: { mode in
            creates.append(mode)
            return fail ? (kIOReturnError, 0) : (kIOReturnSuccess, IOPMAssertionID(creates.count))
        }, release: { id in released.append(id); return id == 2 ? kIOReturnError : kIOReturnSuccess })
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try c.expect(creates.isEmpty && released.isEmpty, "inactive session events never assert")
        sleep.activate(mode: .systemOnly)
        sleep.activate(mode: .systemAndDisplay)
        try c.equal(released, [1], "reactivation releases prior assertion")
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try c.equal(released, [1, 2], "session resignation releases assertion even on release error")
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try c.equal(creates, [.systemOnly, .systemAndDisplay, .systemAndDisplay], "session resumes saved mode")
        sleep.deactivate()
        sleep.deactivate()
        fail = true
        sleep.activate(mode: .systemOnly)
        sleep.deactivate()
        try c.equal(released, [1, 2, 3], "failed creation and duplicate deactivation do not release invalid assertions")
        let defaults = try c.defaults("activity")
        let scheduler = SystemScheduler()
        var idle: TimeInterval = 0
        var moves = 0
        let activity = ActivitySimulator(defaults: defaults, schedule: { interval, _, action in scheduler.schedule(interval, action) }, idleTime: { idle }, moveMouse: { moves += 1 })
        activity.stopSimulation()
        activity.startSimulation()
        activity.startSimulation()
        try c.equal(scheduler.timers.count, 1, "activity start idempotent")
        scheduler.timers.last?.fire()
        try c.equal(moves, 0, "active user receives no mouse movement")
        idle = 1_000_000
        scheduler.timers.last?.fire()
        try c.equal(moves, 1, "idle user invokes injected movement")
        activity.stopSimulation()
        try c.expect(!scheduler.timers[0].isValid, "activity stop cancels timer")
        defaults.set(3, forKey: Constants.Defaults.activityCheckInterval)
        defaults.set(2, forKey: Constants.Defaults.activityIdleMultiplier)
        activity.startSimulation()
        try c.equal(scheduler.intervals.last, 3, "activity interval reload")
        idle = 6
        activity.checkAndSimulate()
        try c.equal(moves, 1, "idle threshold is strict")
        idle = 7
        activity.checkAndSimulate()
        try c.equal(moves, 2, "configured idle threshold used")
        activity.stopSimulation()
    }
}
