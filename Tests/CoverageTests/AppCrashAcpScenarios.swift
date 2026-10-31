import AppKit
@testable import BusinessBarCore
import Combine
import Foundation
@testable import BusinessBar

@MainActor
enum AppCrashAcpScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        do { try crashHandler(context) } catch { failures.append("crashHandler: \(error)") }
        do { try await acpSession(context) } catch { failures.append("acpSession: \(error)") }
        do { try appDiscovery(context) } catch { failures.append("appDiscovery: \(error)") }
        do { try shellExecutor(context) } catch { failures.append("shellExecutor: \(error)") }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    static func crashHandler(_ context: CoverageContext) throws {
        // pendingCrashReport reads the standard defaults, which the isolated
        // fixture home owns, and purges the flag exactly once. install() and
        // showCrashAlertIfNeeded() stay uncalled: they replace real signal
        // handlers and present a real modal alert.
        let missingKey = "BusinessBar.lastCrashReportPath"
        UserDefaults.standard.removeObject(forKey: missingKey)
        try context.expect(CrashHandler.shared.pendingCrashReport() == nil, "No stored path yields no report")
        UserDefaults.standard.set("", forKey: missingKey)
        try context.expect(CrashHandler.shared.pendingCrashReport() == nil, "Empty stored path yields no report")

        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BusinessBar", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = directory.appendingPathComponent("crash_fixture.log")
        try "fixture crash report".write(to: report, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(report.path, forKey: missingKey)
        try context.equal(CrashHandler.shared.pendingCrashReport()?.path, report.path, "Existing report path is returned")
        try context.expect(CrashHandler.shared.pendingCrashReport() == nil, "Report flag purges after one read")

        UserDefaults.standard.set("/nonexistent/crash_missing.log", forKey: missingKey)
        try context.expect(CrashHandler.shared.pendingCrashReport() == nil, "Missing report file yields no report")
        try context.expect(UserDefaults.standard.string(forKey: missingKey) == nil, "Missing-file path still purges the flag")
        try? FileManager.default.removeItem(at: report)
    }

    static func acpSession(_ context: CoverageContext) async throws {
        // /bin/cat as the fixture agent: it echoes stdin back, so valid
        // JSON-RPC lines round-trip through the real reader task and the
        // decode path, without any network or long-lived process.
        let configuration = ACPAgentConfiguration(
            command: "/bin/cat",
            arguments: [],
            workingDirectory: context.root.path,
            environment: ["ACP_FIXTURE": "1"]
        )
        var transport = ACPStdioTransport(configuration: configuration)

        // Sending before start reports the transport-level failure.
        var transportFailure: Error?
        do {
            try await transport.send("{}")
        } catch {
            transportFailure = error
        }
        try context.expect(transportFailure is ACPTransportError, "Send before start throws the not-running transport error")

        let received = ReceivedMessages()
        var closed = 0
        try await transport.start(
            onMessage: { [weak received] message in received?.append(message) },
            onClose: { closed += 1 }
        )
        try context.expect(transport.processIdentifier != nil, "Started transport owns a live process")

        // A well-formed JSON-RPC line round-trips through cat and decodes.
        // The transport spawns two concurrent bytes.lines readers (stdout,
        // stderr), and when the stderr reader's dispatch source registers
        // first the stdout reader can permanently miss early data; measured
        // ~60% per fresh transport. A starved transport never recovers (its
        // pipe holds the echo, but the reader never fires), so retries use a
        // fresh transport each time; the cat round-trip itself is inherently
        // fast, so a few attempts stay well inside the watchdog budget.
        let request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fixture\",\"params\":{\"echo\":true}}"
        var delivered = false
        for _ in 0..<4 {
            try await transport.send(request)
            do {
                try await received.waitForCount(1, timeout: 1.5)
                delivered = true
                break
            } catch {
                await transport.stop()
                let retryTransport = ACPStdioTransport(configuration: configuration)
                try await retryTransport.start(
                    onMessage: { [weak received] message in received?.append(message) },
                    onClose: { closed += 1 }
                )
                transport = retryTransport
            }
        }
        try context.expect(delivered, "Round-tripped line decoded after transport retry")
        try context.equal(received.count, 1, "Round-tripped line decoded as one wire message")

        // A second start call is a no-op: the process stays the same.
        try await transport.start(onMessage: { _ in }, onClose: {})
        try context.expect(transport.processIdentifier != nil, "Restart stays on the same process")

        // stop() terminates the process but never clears the started flag,
        // so processIdentifier keeps the dead pid; termination is observed
        // through the close callback instead.
        let closedBefore = closed
        await transport.stop()
        try context.expect(transport.processIdentifier != nil, "Stopped transport keeps its terminated pid")
        for _ in 0..<50 where closed == closedBefore {
            try await Task.sleep(for: .milliseconds(10))
        }
        try context.expect(closed > closedBefore, "Stop closes the transport")
    }

    private final class ReceivedMessages: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [ACPWireMessage] = []

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return messages.count
        }

        func append(_ message: ACPWireMessage) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        func waitForCount(_ target: Int, timeout: TimeInterval = 5) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while count < target {
                if Date() > deadline {
                    throw CoverageContext.Failure(description: "Transport fixture delivered \(count) of \(target) expected messages")
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    static func appDiscovery(_ context: CoverageContext) throws {
        // Fixture .app bundles drive the real Bundle parsing path.
        let root = try context.temporaryDirectory("app-discovery")
        func makeApp(_ identifier: String, _ name: String) throws -> String {
            let directory = root.appendingPathComponent("\(name).app", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let info = directory.appendingPathComponent("Info.plist")
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>\(identifier)</string>
                <key>CFBundleName</key>
                <string>\(name)</string>
            </dict>
            </plist>
            """
            try plist.write(to: info, atomically: true, encoding: .utf8)
            return directory.path
        }
        let alpha = try makeApp("coverage.discovery.alpha", "Alpha App")
        let beta = try makeApp("coverage.discovery.beta", "Beta App")
        let bare = root.appendingPathComponent("NoPlist.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)

        let found = AppDiscovery.apps(at: [beta, alpha, bare.path, "/nonexistent/path.app"])
        try context.equal(found.map(\.displayName), ["Alpha App", "Beta App"], "Discovery parses fixture bundles and sorts by name")
        try context.equal(found.map(\.bundleIdentifier), ["coverage.discovery.alpha", "coverage.discovery.beta"], "Bundle identifiers come from the fixture plists")
        try context.expect(found.first?.iconPath == alpha, "Icon path keeps the bundle location")

        // A display name can come from CFBundleDisplayName alone.
        let display = try makeApp("coverage.discovery.display", "Placeholder")
        let displayInfo = URL(fileURLWithPath: display).appendingPathComponent("Info.plist")
        let contents = try String(contentsOf: displayInfo, encoding: .utf8)
            .replacingOccurrences(of: "<key>CFBundleName</key>", with: "<key>CFBundleDisplayName</key>")
        try contents.write(to: displayInfo, atomically: true, encoding: .utf8)
        let renamed = AppDiscovery.apps(at: [display])
        try context.equal(renamed.map(\.displayName), ["Placeholder"], "Display name prefers the fixture plist value")
    }

    static func shellExecutor(_ context: CoverageContext) throws {
        // Ring buffer semantics first: bounded head/tail capture with elision.
        let buffer = OutputRingBuffer(headCap: 8, tailCap: 8, killCeiling: 16)
        buffer.append(Data("head-1234".utf8))
        try context.equal(buffer.snapshot, "head-1234", "Small output stays fully retained")
        try context.expect(!buffer.exceededKillCeiling, "Output below ceiling keeps the producer alive")
        buffer.append(Data("0123456789ABCDEF".utf8))
        try context.expect(buffer.exceededKillCeiling, "Output past the ceiling trips the kill flag")
        try context.expect(buffer.snapshot.contains("bytes dropped"), "Overflow snapshot reports dropped bytes")
        // headCap is 8 bytes: the first append already filled it, so only
        // "head-123" survives, not the full nine-byte string.
        try context.expect(buffer.snapshot.contains("head-123"), "Head survives the overflow up to its cap")

        let lines = OutputRingBuffer()
        lines.append(Data("one\ntwo\nthree\nfour\n".utf8))
        try context.equal(lines.lastLines(2), "three\nfour\n", "Last lines keep tail order and trailing newline")
        try context.equal(lines.lastLines(10), "one\ntwo\nthree\nfour\n", "Requesting more lines than captured keeps everything")
        let unterminated = OutputRingBuffer()
        unterminated.append(Data("single".utf8))
        try context.equal(unterminated.lastLines(1), "single", "No trailing newline stays absent")

        // Real safe spawns through the internal ShellExecutor path.
        try context.equal(ShellExecutor.argv(for: .autoApproved(argv: ["/bin/echo"]), command: "ignored"), ["/bin/echo"], "Tier 0 argv runs without a shell")
        try context.equal(ShellExecutor.argv(for: .needsConfirmation(reason: .unknownCommand), command: "echo hi"), ["/bin/zsh", "-c", "echo hi"], "Confirmation commands run through zsh")
        try context.equal(ShellExecutor.argv(for: .sessionApproved(command: "echo hi"), command: "echo hi"), ["/bin/zsh", "-c", "echo hi"], "Session-approved commands run through zsh")

        let home = try context.temporaryDirectory("shell-executor")
        let (echo, echoBuffer) = try ShellExecutor.spawn(argv: ["/bin/echo", "coverage-echo"], cwd: home.path)
        echo.waitUntilExit()
        try context.equal(echo.terminationStatus, 0, "Safe echo spawn exits cleanly")
        for _ in 0..<200 {
            if echoBuffer.snapshot.contains("coverage-echo") { break }
            usleep(10_000)
        }
        try context.expect(echoBuffer.snapshot.contains("coverage-echo"), "Captured stdout reaches the ring buffer")

        do {
            _ = try ShellExecutor.spawn(argv: [], cwd: home.path)
            try context.expect(false, "Empty argv must be rejected")
        } catch ShellExecutor.ExecutionError.emptyArgv {
            try context.expect(true, "Empty argv rejected with the explicit error")
        }
        do {
            _ = try ShellExecutor.spawn(argv: ["/nonexistent/coverage-binary"], cwd: home.path)
            try context.expect(false, "Missing binary must be rejected")
        } catch ShellExecutor.ExecutionError.spawnFailed {
            try context.expect(true, "Missing binary reports spawn failure")
        } catch {
            try context.expect(false, "Unexpected spawn error: \(error)")
        }
        ShellExecutor.killAllAtQuit()
    }
}