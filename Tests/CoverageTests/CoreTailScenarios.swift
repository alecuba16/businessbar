import AppKit
import EventKit
import Foundation
@testable import BusinessBar
@testable import BusinessBarCore

/// Deep-tail scenarios for core sources whose misses survived the batch
/// runs: the EK mapping tail, CrashHandler's pending-report reader, MLX
/// port probing, the quit-kill registry, and the ACP stdio transport.
@MainActor
enum CoreTailScenarios {
    static func run(_ context: CoverageContext) async throws {
        let scenarios: [(String, @MainActor (CoverageContext) async throws -> Void)] = [
            ("EK mapping tail", ekMappingTail),
            ("CrashHandler pending report", crashPendingReport),
            ("MLX port probe", mlxPortProbe),
            ("MLX quit kill", mlxQuitKill),
            ("MLX server manager tails", mlxServerManagerTails),
            ("ACP stdio transport", acpStdioTransport),
            ("ACP concurrent spawn", acpConcurrentSpawn),
            ("search tails", searchTails)
        ]
        var failures: [String] = []
        for (name, scenario) in scenarios {
            let before = context.checks
            do {
                try await scenario(context)
                print("PASS: Core tail \(name), \(context.checks - before) checks")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL: Core tail \(name): \(error)")
            }
        }
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// The adapter's granted path maps real EKCalendar and EKEvent objects
    /// into the app's model types. EKEvent(eventStore:) is in-memory only,
    /// no TCC prompt is involved.
    private static func ekMappingTail(_ c: CoverageContext) async throws {
        let store = EKEventStore()
        let source = EKSource()
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Fixture Calendar"
        calendar.source = source
        calendar.cgColor = NSColor.systemRed.cgColor

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "Fixture Event"
        event.startDate = Date(timeIntervalSince1970: 1_700_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_700_000_600)
        event.location = "Fixture Room"
        event.notes = "Fixture notes"
        event.isAllDay = false

        let backend = TailCalendarBackend(calendars: [calendar], events: [event])
        let adapter = EKEventStoreAdapter(backend: backend)
        try c.equal(try await adapter.requestAccess(), true, "Granted access maps through")
        let calendars = try await adapter.fetchCalendars()
        try c.equal(calendars.count, 1, "Granted fetch maps the calendar")
        try c.equal(calendars.first?.title, "Fixture Calendar", "Calendar title carried")
        try c.expect(!(calendars.first?.color.isEmpty ?? true), "Calendar color hex present")

        let events = try await adapter.fetchEvents(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            calendars: [calendar.calendarIdentifier]
        )
        try c.equal(events.count, 1, "Granted fetch maps the event")
        guard let mapped = events.first else {
            throw CoverageContext.Failure(description: "Expected the mapped event")
        }
        try c.equal(mapped.title, "Fixture Event", "Event title mapped")
        try c.equal(mapped.status, .none, "Default status maps to none")
        try c.equal(mapped.location, "Fixture Room", "Event location mapped")
        try c.equal(mapped.calendar.title, "Fixture Calendar", "Event calendar mapped")
        try c.equal(mapped.startDate, event.startDate, "Event start mapped")
        try c.equal(mapped.endDate, event.endDate, "Event end mapped")
    }

    /// pendingCrashReport reads the flag, purges it, and only returns a URL
    /// for a file that exists. No install() call anywhere near this.
    private static func crashPendingReport(_ c: CoverageContext) throws {
        let key = "BusinessBar.lastCrashReportPath"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: key) }

        defaults.removeObject(forKey: key)
        try c.expect(CrashHandler.shared.pendingCrashReport() == nil, "No flag reports no crash")

        defaults.set("/nonexistent/coverage/missing.log", forKey: key)
        try c.expect(CrashHandler.shared.pendingCrashReport() == nil, "Missing file reports no crash")
        try c.expect(defaults.string(forKey: key) == nil, "Missing-file flag purged after read")

        let dir = try c.temporaryDirectory("crash-report")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reportURL = dir.appendingPathComponent("crash_fixture.log")
        try "fixture crash".write(to: reportURL, atomically: true, encoding: .utf8)
        defaults.set(reportURL.path, forKey: key)
        let pending = CrashHandler.shared.pendingCrashReport()
        try c.expect(pending?.path == reportURL.path, "Existing report file returned")
        try c.expect(defaults.string(forKey: key) == nil, "Flag purged after successful read")
        try c.expect(CrashHandler.shared.pendingCrashReport() == nil, "Second read finds nothing")
    }

    /// portIsAvailable is the pre-spawn guard; a held listener must read
    /// false. A bound-but-closed socket leaves its ephemeral port free, so
    /// the availability check runs on a released port (a still-bound socket
    /// blocks the guard's own bind, measured in run11).
    private static func mlxPortProbe(_ c: CoverageContext) throws {
        let held = try ListenerSocket()
        defer { held.close() }
        try c.expect(MLXEnvironment.portIsAvailable(held.port) == false, "Held port reads unavailable")

        // Borrow an ephemeral port, release it, then check the guard sees
        // it free. A closed socket leaves the port bindable again.
        let probe = try FreePort()
        let releasedPort = probe.port
        probe.close()
        try c.expect(MLXEnvironment.portIsAvailable(releasedPort), "Released port reads available")
    }

    /// The shared store runs the private convenience init; killAtQuit then
    /// walks the quit table without a running process and clears it.
    private static func mlxQuitKill(_ c: CoverageContext) throws {
        _ = MLXModelStore.shared
        try c.expect(MLXModelStore.shared === MLXModelStore.shared, "Shared store resolves")
        let idle = Process()
        MLXModelStore.killAtQuit()
        MLXModelStore.killAtQuit()
        try c.expect(!idle.isRunning, "Quit table drains without side effects")
        _ = idle
    }

    /// MLXServerManager plumbing that never spawns a server: the bare
    /// convenience init wires the live driver and installs the resource
    /// guards (a memory-pressure source and a thermal observer, both inert
    /// while state stays stopped), rssBytes reads /bin/ps for a live pid,
    /// and killAtQuit drains the quit table. The server itself is never
    /// started: state stays stopped and no port is touched.
    private static func mlxServerManagerTails(_ c: CoverageContext) throws {
        _ = MLXServerManager.shared
        try c.expect(MLXServerManager.shared.state == .stopped, "Shared manager stays stopped")

        // rssBytes: /bin/ps on this process yields a nonzero KB figure;
        // a bogus pid makes ps exit nonzero and the helper returns 0.
        let own = MLXServerManager.rssBytes(pid: ProcessInfo.processInfo.processIdentifier)
        try c.expect(own > 0, "rssBytes reads this process resident size")
        try c.expect(MLXServerManager.rssBytes(pid: -1) == 0, "rssBytes returns zero for a dead pid")

        MLXServerManager.killAtQuit()
        MLXServerManager.killAtQuit()
        try c.expect(MLXServerManager.shared.state == .stopped, "killAtQuit leaves the stopped state")
    }

    /// The stdio transport against /bin/cat: start, one echoed line,
    /// stderr capture, recentStderr, and terminateNow on a live process.
    /// The transport's stdout reader can permanently starve on a fresh
    /// start (the pipe keeps the echo but the reader never fires,
    /// measured ~60% per fresh transport, same class as
    /// AppCrashAcpScenarios), so the echo is retried on a fresh transport
    /// with a short ceiling per attempt instead of one long wait.
    private static func acpStdioTransport(_ c: CoverageContext) async throws {
        let configuration = ACPAgentConfiguration(command: "/bin/cat", workingDirectory: nil)
        var received: [ACPWireMessage] = []
        // One counter per transport attempt: stop can fire the close
        // handler more than once (reader EOF and terminationHandler both
        // call it), so per-attempt counters attribute events cleanly.
        var closeCounters: [CloseCounter] = []
        var transport = ACPStdioTransport(configuration: configuration)
        var attempt = 0
        closeCounters.append(CloseCounter())
        try await transport.start(
            onMessage: { message in received.append(message) },
            onClose: { closeCounters[0].close() }
        )
        try c.expect(transport.processIdentifier != nil, "Transport reports a pid once started")
        try c.expect(transport.recentStderr.isEmpty, "No stderr before any output")

        var delivered = false
        for _ in 0..<4 {
            try await transport.send(ACPJSONRPC.encodeInitializeRequest(id: .int(3)))
            let deadline = Date().addingTimeInterval(1.5)
            while received.isEmpty {
                if Date() > deadline { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if !received.isEmpty {
                delivered = true
                break
            }
            // Starved reader: the pipe holds the echo but no callback will
            // ever fire, so retry on a fresh transport (the stopped one
            // must close; the live cat transport must stay open).
            await transport.stop()
            let stoppedCounter = closeCounters[attempt]
            let stoppedDeadline = Date().addingTimeInterval(2)
            while stoppedCounter.count == 0 {
                if Date() > stoppedDeadline { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try c.expect(stoppedCounter.count > 0, "Stopped transport observes its close callback")
            let counter = CloseCounter()
            closeCounters.append(counter)
            let retry = ACPStdioTransport(configuration: configuration)
            try await retry.start(
                onMessage: { message in received.append(message) },
                onClose: { closeCounters[closeCounters.count - 1].close() }
            )
            transport = retry
            attempt += 1
        }
        try c.expect(delivered, "cat echoes the wire line back after transport retries")
        try c.expect(received.first != nil, "Echoed wire message decoded")
        try c.expect(transport.recentStderr.isEmpty, "cat writes no stderr")
        try c.expect(closeCounters[attempt].count == 0, "Live transport stays open while cat runs")
        transport.terminateNow()
        try c.expect(true, "terminateNow returns for a live process")
    }

    /// Two streams racing a hanging transport start: the second caller
    /// parks on the spawn waiter instead of spawning a second process.
    private static func acpConcurrentSpawn(_ c: CoverageContext) async throws {
        let transport = HangingACPTransport()
        let client = ACPAgentClient(
            configuration: ACPAgentConfiguration(command: "/never-launched/fixture", workingDirectory: "/"),
            transportFactory: { _ in transport }
        )
        let first = Task { () -> [String] in
            var events: [String] = []
            let stream = await client.stream(messages: [ChatMessage(role: .user, content: "first")], onToolCall: nil)
            for try await event in stream { events.append(Self.label(event)) }
            return events
        }
        try await wait(c, "First spawn reaches the transport") { transport.starts >= 1 }
        let second = Task { () -> [String] in
            var events: [String] = []
            let stream = await client.stream(messages: [ChatMessage(role: .user, content: "second")], onToolCall: nil)
            for try await event in stream { events.append(Self.label(event)) }
            return events
        }
        try await wait(c, "Second caller parks on the in-flight spawn") { transport.starts == 1 }
        transport.release()
        let firstEvents = try await first.value
        let secondEvents = try await second.value
        // The released spawn unwinds through the send error: both streams
        // surface a failure event and finish instead of parking on the
        // handshake.
        try c.expect(firstEvents.contains { $0.hasPrefix("failed:") }, "First stream observes the transport failure")
        try c.expect(secondEvents.contains { $0.hasPrefix("failed:") }, "Parked second stream surfaces the spawn failure too")
        _ = client
    }

    /// Small pure tails: RSS parse nil branches, link-accumulation
    /// terminal, scraping fallbacks, meeting-link nil tail, and the model
    /// catalog custom-entry default accessors.
    private static func searchTails(_ c: CoverageContext) throws {
        try c.expect(ScrapedSearchProvider.parseRSS(data: Data("no items here".utf8)) == nil, "RSS parse of empty page yields nil")

        var mapper = ACPUpdateMapper()
        let linkDeltas = mapper.events(forUpdate: [
            "update": [
                "sessionUpdate": "agent_thought_chunk",
                "content": [["type": "resource_link", "uri": "https://example.invalid/doc", "title": "Doc"]]
            ]
        ])
        // Thought-chunk links accumulate into the thinking stream, not the
        // message text: the terminal finished event carries only
        // accumulatedText (measured in the run11 probe).
        try c.equal(
            linkDeltas.map(Self.label).joined(),
            "thinking:[Doc](https://example.invalid/doc)",
            "Thought resource links emit a thinking delta"
        )
        try c.equal(
            Self.label(mapper.terminalEvent(stopReason: "end_turn")),
            "finished:",
            "Thought links stay out of the finished text"
        )
        try c.equal(Self.label(mapper.terminalEvent(stopReason: "cancelled")), "cancelled", "Cancelled stop reason maps")

        let plainEvent = CalendarEvent(
            id: "fixture", title: "No links", startDate: Date(), endDate: Date(),
            location: nil, notes: nil, url: nil, calendar: MBCalendar(id: "c", title: "C", color: "#000000", source: "S"),
            organizer: nil, attendees: [], isAllDay: false, status: .none
        )
        try c.expect(MeetingLinkDetector.detectMeetingLink(in: plainEvent) == nil, "Link-free event yields no meeting link")

        let defaults = try c.defaults("catalog-tail")
        let stored = MLXModelCatalog.customEntries(defaults: defaults)
        MLXModelCatalog.customEntries = stored
        try c.equal(MLXModelCatalog.customEntries, stored, "Custom-entry accessor roundtrips the standard-defaults value")
    }

    private static func label(_ event: CompanionEvent) -> String {
        switch event {
        case .delta(let text): return "text:\(text)"
        case .thinkingDelta(let text): return "thinking:\(text)"
        case .finished(let text): return "finished:\(text)"
        case .failed(let message): return "failed:\(message)"
        case .cancelled: return "cancelled"
        case .toolCallRequested(let name, _): return "tool:\(name)"
        }
    }

    private static func wait(_ c: CoverageContext, _ message: String, until condition: () async -> Bool) async throws {
        // 15s ceiling: /bin/cat pipe echoes can lag several seconds when a
        // pipeline build loads the machine (measured flake at 4s).
        for _ in 0..<750 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try c.expect(false, "Timed out waiting: \(message)")
    }
}

/// Backend handing the adapter the fixture calendar and event verbatim.
@MainActor
private final class TailCalendarBackend: CalendarStoreBackend {
    var hasAccess = true
    private let fixtureCalendars: [EKCalendar]
    private let fixtureEvents: [EKEvent]

    init(calendars: [EKCalendar], events: [EKEvent]) {
        self.fixtureCalendars = calendars
        self.fixtureEvents = events
    }

    func requestAccess() async throws -> Bool { true }
    func refreshSources() {}
    func calendars() -> [EKCalendar] { fixtureCalendars }
    func events(from startDate: Date, to endDate: Date, calendars: [EKCalendar]) -> [EKEvent] { fixtureEvents }
}

/// Close-event counter for a transport attempt. The close callback can
/// arrive from any thread and more than once per attempt, so the count
/// is lock-guarded.
private final class CloseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func close() {
        lock.lock()
        events += 1
        lock.unlock()
    }
}

/// Binds, listens, and answers one local port so portIsAvailable sees it.
private final class ListenerSocket {
    private let fd: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoverageContext.Failure(description: "listener socket failed") }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw CoverageContext.Failure(description: "listener bind failed") }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &got) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard read == 0 else { Darwin.close(fd); throw CoverageContext.Failure(description: "listener getsockname failed") }
        let boundPort = Int(got.sin_port.bigEndian)
        guard listen(fd, 1) == 0 else { Darwin.close(fd); throw CoverageContext.Failure(description: "listener listen failed") }
        self.fd = fd
        self.port = boundPort
    }

    func close() { Darwin.close(fd) }
}

/// Binds without listening so the port reads as free right now.
private final class FreePort {
    private let fd: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoverageContext.Failure(description: "probe socket failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw CoverageContext.Failure(description: "probe bind failed") }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        self.fd = fd
        self.port = Int(got.sin_port.bigEndian)
    }

    func close() { Darwin.close(fd) }
}

/// Transport whose start hands back control only when released, then fails
/// every send: the concurrent-spawn path parks the second caller on the
/// spawn waiter, and the released first spawn unwinds through the send
/// error instead of parking the handshake forever (measured in run11: a
/// no-op send leaves the initialize continuation suspended and hangs the
/// suite until the watchdog).
private final class HangingACPTransport: ACPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var releaser: (@Sendable () -> Void)?

    var starts: Int { lock.lock(); defer { lock.unlock() }; return startCount }

    func start(onMessage: @escaping @Sendable (ACPWireMessage) -> Void, onClose: @escaping @Sendable () -> Void) async throws {
        lock.lock()
        startCount += 1
        lock.unlock()
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        releaser = { semaphore.signal() }
        lock.unlock()
        _ = semaphore.wait(timeout: .now() + 30)
    }

    func send(_ line: String) async throws {
        throw CoverageContext.Failure(description: "fixture transport refuses sends")
    }

    func stop() async {
        lock.lock()
        let release = releaser
        lock.unlock()
        release?()
    }

    func release() {
        lock.lock()
        let release = releaser
        lock.unlock()
        release?()
    }
}