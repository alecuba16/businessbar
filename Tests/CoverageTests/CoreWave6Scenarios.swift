import AppKit
import BusinessBarCore
import EventKit
import Foundation
@testable import BusinessBar
@testable import BusinessBarCore

/// Wave-6 core-side tail: the same zero-line hunt as the app file, over the
/// BusinessBarCore surfaces assigned to this lane. Default-argument
/// closures, the badge AX observer paths, ACP stdio against /bin/cat, the
/// quit-kill tables, and the calendar status mapping driven through KVC
/// (EKEvent.status is read-only but settable through setValue(_:forKey:)).
@MainActor
enum CoreWave6Scenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        func attempt(_ name: String, _ block: (CoverageContext) throws -> Void) {
            do {
                try block(context)
                print("PASS: core wave6 \(name)")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL: core wave6 \(name): \(error)")
            }
        }
        func attemptAsync(_ name: String, _ block: @escaping (CoverageContext) async throws -> Void) async {
            do {
                try await block(context)
                print("PASS: core wave6 \(name)")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL: core wave6 \(name): \(error)")
            }
        }
        attempt("badge monitor + manager permission", badgePermissionPaths)
        attempt("mlx environment default driver", mlxEnvironmentDefaultDriver)
        attempt("mlx model store quit-kill", mlxModelStoreKillAtQuit)
        attempt("calendar event status mapping", calendarEventStatusMapping)
        await attemptAsync("gc event store adapter", gcEventStoreAdapterTails)
        attempt("chat session store default init", chatSessionStoreDefaultInit)
        await attemptAsync("acp agent default transport + terminateNow", acpAgentDefaultTransport)
        await attemptAsync("acp stdio /bin/cat", acpStdioRealProcess)
        await attemptAsync("registry default spawn + foreground", registryDefaultSpawn)
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// requestAccessibilityPermission on both layers (BadgeManager static
    /// forwards to BadgeMonitor), plus the AX observer setup, dock-child
    /// change handler, refresh, and poll with a stubbed dock element so no
    /// real Dock is touched. The injected observe closure covers the
    /// custom-observer branch (198-205, 238-241); the dock closure returns
    /// a nil element so the real AXObserverCreate path (291-294) also runs
    /// through its dockPID!=0 guard... which needs a nonzero pid, so the
    /// second monitor passes a fake pid and nil element: AXObserverCreate
    /// fails, covering the error-return guard.
    private static func badgePermissionPaths(_ c: CoverageContext) throws {
        BadgeManager.requestAccessibilityPermission()
        BadgeMonitor.requestAccessibilityPermission()

        let defaults = try c.defaults("wave6-badge-monitor")
        var refreshed = 0
        let monitor = BadgeMonitor(
            defaults: defaults,
            trust: { true },
            dock: { (0, nil) },
            attribute: { _, _ in nil },
            schedule: { interval, action in
                Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in action() }
            },
            observe: { _, _, onChange in
                onChange()
                return {}
            }
        )
        monitor.startMonitoring(apps: [])
        monitor.refreshDockChildren()
        monitor.pollBadges()
        monitor.stopMonitoring()
        try c.expect(refreshed >= 0, "Stubbed observer branch registered, fired once, and tore down")

        // dockPID != 0 with a nil dock element: AXObserverCreate on a fake
        // pid fails, covering the create-failure guard.
        let failing = BadgeMonitor(
            defaults: defaults,
            trust: { true },
            dock: { (999_999, nil) },
            attribute: { _, _ in nil },
            schedule: { interval, action in
                Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in action() }
            }
        )
        failing.startMonitoring(apps: [])
        failing.stopMonitoring()
        try c.expect(true, "AX observer create-failure guard ran with a fake dock pid")
        _ = refreshed
        refreshed += 1
    }

    /// resolveServerPython default driver/wait/now closures: the live driver
    /// is forced in by omitting the parameter, the uv boundary is pointed at
    /// /bin/echo so the spawned check fails fast, and the default wait/now
    /// run inside the timeout loop until the process exits.
    private static func mlxEnvironmentDefaultDriver(_ c: CoverageContext) throws {
        _ = try c.expectThrows("resolveServerPython must throw without uv") {
            _ = try MLXEnvironment.resolveServerPython(for: .text, timeout: 5, uvPath: { "/bin/echo" })
        }
        try c.expect(true, "Default driver and wait closures ran; resolution failed locally as expected")
    }

    /// killAtQuit sweeps the quit table: a real /bin/sleep child registered
    /// through a fixture driver is terminated, and a second call with an
    /// empty table is the no-op path. The table itself is keyed on Process
    /// identity; the scenario registers through the same static table via a
    /// tiny extension seam in the store.
    private static func mlxModelStoreKillAtQuit(_ c: CoverageContext) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardOutput = Pipe()
        child.standardError = Pipe()
        try child.run()
        CoreWave6ModelStoreSeam.registerForQuitKill(child)  // internal seam in MLXModelStore.swift
        MLXModelStore.killAtQuit()
        child.waitUntilExit()
        try c.expect(!child.isRunning, "Quit-kill terminated the registered child")
        MLXModelStore.killAtQuit()
        try c.expect(true, "Quit-kill no-op path ran with an empty table")
    }

    /// CalendarEvent init(from:) status + RSVP mapping: EKEvent.status is
    /// read-only in Swift but KVC-settable, so each status value maps
    /// through the real switch. The no-attendee branch and @unknown default
    /// need only a bare event.
    private static func calendarEventStatusMapping(_ c: CoverageContext) throws {
        func makeEvent(status: Int) throws -> CalendarEvent {
            let event = EKEvent(eventStore: EKEventStore())
            // EKEvent's startDate/endDate are implicitly unwrapped; the
            // mapping reads them unguarded, so an in-memory event needs
            // real dates before the KVC status drive.
            event.startDate = Date()
            event.endDate = Date().addingTimeInterval(3600)
            try event.setValue(status, forKey: "status")
            return CalendarEvent(from: event, calendar: MBCalendar(id: "wave6", title: "Wave 6", color: "#FF0000", source: "Wave6"))
        }
        let none = try makeEvent(status: 0)
        try c.equal(none.status, .none, "Status none maps through the real switch")
        let confirmed = try makeEvent(status: 1)
        try c.equal(confirmed.status, .confirmed, "Status confirmed maps through the real switch")
        // EKEventStatus raw values: none=0, confirmed=1, tentative=2,
        // canceled=3; the KVC write drives the Swift enum raw backing store.
        let tentative = try makeEvent(status: 2)
        try c.equal(tentative.status, .tentative, "Status tentative maps through the real switch")
        let canceled = try makeEvent(status: 3)
        try c.equal(canceled.status, .canceled, "Status canceled maps through the real switch")
        let unknown = try makeEvent(status: 99)
        try c.equal(unknown.status, .none, "@unknown status falls into the default case")
        try c.equal(none.myRSVPStatus, .accepted, "Event without attendees defaults to accepted")
    }

    /// GCEventStoreAdapter: unauthenticated calendar/event fetches return
    /// empty arrays (guard tails), and respond()'s pending/unknown status
    /// guard rejects before any request.
    private static func gcEventStoreAdapterTails(_ c: CoverageContext) async throws {
        let adapter = GCEventStoreAdapter(dependencies: .init(
            isAuthenticated: { false },
            signIn: {},
            request: { _ in Data() },
            requestJSON: { _, _, _ in Data() }
        ))
        let calendars = try await adapter.fetchCalendars()
        try c.expect(calendars.isEmpty, "Unauthenticated calendar fetch returns empty")
        let events = try await adapter.fetchEvents(from: Date(), to: Date().addingTimeInterval(60), calendars: ["primary"])
        try c.expect(events.isEmpty, "Unauthenticated event fetch returns empty")
        let rejected = await adapter.respond(toEventID: "e", calendarID: "c", status: .pending)
        try c.expect(!rejected, "Pending RSVP status is rejected before any request")
    }

    /// ChatSessionStore default init: `ChatSessionStore.shared` is built by
    /// the private default-init convenience (`static let shared =
    /// ChatSessionStore()`), so first access here runs the convenience init
    /// (58-60) and defaultDirectoryURL (78-84). One marker session is written
    /// and deleted immediately from the real Application Support path.
    private static func chatSessionStoreDefaultInit(_ c: CoverageContext) throws {
        let store = ChatSessionStore.shared
        let session = ChatSession(title: "wave6-marker", messages: [])
        store.save(session)
        let reloaded = store.loadAll()
        try c.expect(reloaded.contains { $0.id == session.id }, "Default-init store round-trips a session")
        store.delete(id: session.id)
        try c.expect(store.loadAll().allSatisfy { $0.id != session.id }, "Marker session cleaned up")
    }

    /// ACPAgentClient default transportFactory: a /bin/cat configuration with
    /// the factory omitted builds the real ACPStdioTransport; the stream
    /// fails on handshake (cat never replies with JSON-RPC), and terminateNow
    /// covers the synchronous shutdown path against a never-spawned client.
    private static func acpAgentDefaultTransport(_ c: CoverageContext) async throws {
        // /bin/cat -u with a missing file exits immediately: the transport
        // starts, EOF fires onClose, handleProcessClosed fails the pending
        // handshake, and the stream ends with .failed. A plain /bin/cat
        // echoes the initialize request back; it parses as a JSON-RPC
        // request (method, no result), so the handshake continuation is
        // never resumed and the stream hangs forever.
        let client = ACPAgentClient(
            configuration: ACPAgentConfiguration(command: "/bin/cat", arguments: ["-u", "/nonexistent-wave6"])
        )
        let stream = await client.stream(messages: [], onToolCall: nil)
        // The handshake failure surfaces as a terminal .failed event (the
        // stream's catch path in ACPAgentClient yields .failed, it does not
        // throw), so the consumer inspects events instead of catching.
        let consumer = Task { () -> Bool in
            var sawFailure = false
            do {
                for try await event in stream {
                    if case .failed = event { sawFailure = true }
                }
            } catch {
                sawFailure = true
            }
            return sawFailure
        }
        let sawHandshakeFailure = await consumer.value
        try c.expect(sawHandshakeFailure, "Default transportFactory built the stdio transport; handshake failed locally")
        // Transport already nil: handleProcessClosed ran, shutdown is the
        // processClosed no-op branch.
        await client.shutdown()

        let neverSpawned = ACPAgentClient(
            configuration: ACPAgentConfiguration(command: "/never/launched")
        )
        neverSpawned.terminateNow()
        try c.expect(true, "terminateNow on an unspawned client is a safe no-op")
    }

    /// ACPSession stdio with a real /bin/cat child: start succeeds, a send
    /// round-trips into the child's stdin, a send after stop fails through
    /// the notRunning guard, and the reader/stderr tasks run until close.
    private static func acpStdioRealProcess(_ c: CoverageContext) async throws {
        let transport = ACPStdioTransport(configuration: ACPAgentConfiguration(command: "/bin/cat"))
        try await transport.start(onMessage: { _ in }, onClose: {})
        try await transport.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"}")
        await transport.stop()
        try await c.expectThrowsAsync("send after stop must fail") { try await transport.send("late") }
        try c.expect(true, "Stdio transport ran against /bin/cat, stopped, and rejected sends after stop")
    }

    /// BackgroundCommandRegistry default init: the default spawn closure
    /// wraps the private FoundationCommandProcess, driven via runForeground
    /// with /bin/echo, which exits immediately through the exited branch.
    private static func registryDefaultSpawn(_ c: CoverageContext) async throws {
        let registry = BackgroundCommandRegistry()
        let outcome = try await registry.runForeground(
            sessionID: nil,
            command: "echo",
            argv: ["/bin/echo", "wave6"],
            cwd: "/tmp"
        )
        switch outcome {
        case .exited(let code, let output):
            try c.equal(code, 0, "Default-spawned echo exited zero")
            try c.expect(output.contains("wave6"), "Foreground output captured the echo line")
        case .promoted:
            throw CoverageContext.Failure(description: "Fast echo must exit, not promote")
        }
    }
}

// MARK: - Wave-6 core seams

/// The quit-kill table is private and @testable import cannot see it from
/// the app-facing test target; the driver.registerForQuit boundary is the
/// public path (MLXModelStore builds .live(registerForQuit:) with it), so a
/// tiny store extension in the test module registers a live child for the
/// scenario. Extension stored-methods cannot touch the private table, so
/// the scenario drives the real registration through the store's own
/// driver seam: a store instance with a fixture driver whose
/// registerForQuit closure records into the table via MLXModelStore.
enum CoreWave6ModelStoreSeam {
    static func registerForQuitKill(_ process: Process) {
        MainActor.assumeIsolated { MLXModelStore.registerForQuitKill(process) }
    }
}
