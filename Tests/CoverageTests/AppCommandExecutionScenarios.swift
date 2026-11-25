import Foundation
@testable import BusinessBar
@testable import BusinessBarCore

@MainActor
enum AppCommandExecutionScenarios {
    static func run(_ context: CoverageContext) async throws {
        let root = try context.temporaryDirectory("command-execution")
        CompanionConfigService.setCommandDefaultWorkingDir(root.path)
        CompanionConfigService.setCommandPermissionMode(.allow)
        CompanionConfigService.setCommandAllowedPrefixes([])
        CompanionConfigService.setCommandDeniedPrefixes([])
        let runtime = AppCommandRuntime()
        let registry = BackgroundCommandRegistry(spawn: { try runtime.spawn($0, $1) }, now: { Date() }, sleep: { try await Task.sleep(nanoseconds: $0) })
        let controller = CommandToolController(registry: registry, presentation: .init(chooseWorkspace: { nil }, notify: { _ in }))
        let sessionID = UUID()
        controller.beginSession(sessionID)
        let foreground = Task { await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo controlled\"}") }
        try await waitForProcess(runtime, index: 0, context)
        runtime.process(0).finish(7)
        let result = await foreground.value
        try context.equal(result, "exit code 7\ncontrolled output", "Foreground tool formats injected exit and output")
        try context.equal(runtime.arguments.first?.0, ["echo", "controlled"], "Read-only command uses direct argv through injected process")
        try context.equal(runtime.arguments.first?.1, root.path, "Selected workspace reaches executor")
        let background = await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo background\",\"background\":true}")
        try context.expect(background.hasPrefix("started in background. handle:"), "Background tool returns handle")
        try context.equal(controller.backgroundProcesses.count, 1, "Background card refreshed after launch")
        guard let card = controller.backgroundProcesses.first else { throw CoverageContext.Failure(description: "Missing process card") }
        let listing = await controller.handleToolCall(name: "list_background_processes", argumentsJSON: "{}")
        try context.expect(listing.contains(card.id.uuidString) && listing.contains("running"), "Process listing exposes handle and running state")
        let output = await controller.handleToolCall(name: "read_background_output", argumentsJSON: "{\"handle\":\"\(card.id)\",\"lines\":1}")
        try context.equal(output, "controlled output", "Background output comes from injected buffer")
        runtime.process(1).finish(3)
        for _ in 0..<100 {
            let entries = await registry.listBackground(sessionID: sessionID)
            if entries.first?.exitCode != nil { break }
            await Task.yield()
        }
        let completed = await controller.handleToolCall(name: "list_background_processes", argumentsJSON: "{}")
        try context.expect(completed.contains("exited(3)") && completed.contains("normal"), "Completed background card formats exit reason")
        let drained = await controller.drainPendingResults()
        try context.equal(drained.map(\.exitCode), [3], "Completed background results drained for chat")
        let startedForStop = await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo stop\",\"background\":true}")
        try context.expect(startedForStop.hasPrefix("started in background"), "Stop fixture launched via fake")
        guard let running = controller.backgroundProcesses.first(where: { $0.running }) else { throw CoverageContext.Failure(description: "Missing stop fixture") }
        let stop = await controller.handleToolCall(name: "stop_background_process", argumentsJSON: "{\"handle\":\"\(running.id)\"}")
        try context.equal(stop, "stopped", "Stop tool reaches controlled process")
        try context.equal(runtime.process(2).terminations, 1, "Stop terminates fake process once")
        controller.sessionPermissionMode = .ask
        let approval = Task { await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"mkdir safe-fixture\"}") }
        for _ in 0..<1000 {
            if controller.approvalRequest != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.equal(controller.approvalRequest?.command, "mkdir safe-fixture", "Risky command creates approval card")
        controller.decide(.denied)
        let denied = await approval.value
        try context.equal(denied, "denied by user", "Denied approval never executes")
        try context.equal(runtime.arguments.count, 3, "Denied approval does not reach executor")
        runtime.shouldFail = true
        controller.sessionPermissionMode = .allow
        let failure = await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo fails\"}")
        try context.expect(failure.contains("controlled spawn failure"), "Foreground spawn failure surfaced")
        let backgroundFailure = await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo fails\",\"background\":true}")
        try context.expect(backgroundFailure.contains("controlled spawn failure"), "Background spawn failure surfaced")
        await controller.shutdown()
        try await commandExecutionEdges(context)
    }

    /// Branches the happy-path run above never takes: missing workspace
    /// (read_file/list_files), the rm-with-Deny hint, approval timeout
    /// auto-deny, missing query argument, tool dispatch with no configured
    /// search handler, a session-approved Tier 1 prefix, foreground
    /// promotion through the registry watchdog, and sessionApproved argv
    /// building through zsh.
    private static func commandExecutionEdges(_ context: CoverageContext) async throws {
        let root = try context.temporaryDirectory("command-execution-edges")
        let savedWorkingDir = CompanionConfigService.commandDefaultWorkingDir()
        CompanionConfigService.setCommandDefaultWorkingDir(root.path)
        CompanionConfigService.setCommandPermissionMode(.ask)
        CompanionConfigService.setCommandAllowedPrefixes([])
        CompanionConfigService.setCommandDeniedPrefixes([])
        defer {
            CompanionConfigService.setCommandDefaultWorkingDir(savedWorkingDir)
            CompanionConfigService.setCommandPermissionMode(.ask)
            CommandToolController.approvalTimeoutNanosecondsForCoverage = 300_000_000_000
        }

        let runtime = AppCommandRuntime()
        // Short watchdog: 10ms inactivity promotes a hung foreground call.
        let registry = BackgroundCommandRegistry(
            inactivity: 0.01,
            wallClock: 60,
            spawn: { try runtime.spawn($0, $1) },
            now: { Date() },
            sleep: { try await Task.sleep(nanoseconds: $0) }
        )
        let controller = CommandToolController(registry: registry, presentation: .init(chooseWorkspace: { nil }, notify: { _ in }))
        controller.beginSession(UUID())

        // Missing workspace: no session pick, default dir points at a
        // path that does not exist, so the tools refuse before spawning.
        controller.workspaceRoot = ""
        CompanionConfigService.setCommandDefaultWorkingDir("/does-not-exist-businessbar-coverage")
        let noRoot = await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo no-root\"}")
        try context.equal(noRoot, "error: no workspace folder selected. Ask the user to pick one in the panel header.", "run_command without workspace")
        let noRootRead = await controller.handleToolCall(name: "read_file", argumentsJSON: "{\"path\":\"note.txt\"}")
        try context.equal(noRootRead, "error: no workspace folder selected. Ask the user to pick one in the panel header.", "read_file without workspace")
        let noRootList = await controller.handleToolCall(name: "list_files", argumentsJSON: "{}")
        try context.equal(noRootList, "error: no workspace folder selected. Ask the user to pick one in the panel header.", "list_files without workspace")

        // rm with the fileDelete category dial at Deny appends the hint.
        CompanionConfigService.setCommandDefaultWorkingDir(root.path)
        controller.workspaceRoot = root.path
        let savedDeleteMode = CompanionConfigService.commandCategoryMode(.fileDelete)
        CompanionConfigService.setCommandCategoryMode(.deny, for: .fileDelete)
        let refused = await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"rm note.txt\"}")
        try context.expect(refused.hasSuffix("File deletion is set to Deny in Preferences."), "Deny-wins refusal carries the preferences hint")
        CompanionConfigService.setCommandCategoryMode(savedDeleteMode, for: .fileDelete)

        // Approval timeout auto-deny: 20ms timeout, nobody decides.
        CommandToolController.approvalTimeoutNanosecondsForCoverage = 20_000_000
        let timedOut = Task { await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"mkdir edge-fixture\"}") }
        for _ in 0..<1000 {
            if controller.approvalRequest != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let timedOutResult = await timedOut.value
        try context.equal(timedOutResult, "denied by user", "Approval timeout auto-denies without a decision")
        try context.expect(controller.approvalRequest == nil, "Timeout clears the pending card")
        CommandToolController.approvalTimeoutNanosecondsForCoverage = 300_000_000_000

        // Tool dispatch: without a provider the handler itself is nil, so
        // the panel handler reports not-configured; with a scrape provider
        // configured the handler exists and bad arguments surface the
        // missing-query branch inside the config service closure.
        CompanionConfigService.setCommandToolsEnabled(true)
        let handler = controller.makePanelToolHandler()
        try context.expect(handler != nil, "Handler exists for the dispatch checks")
        let unconfigured = await handler?("web_search", "{}")
        try context.equal(unconfigured, "Error: web_search is not configured", "Missing provider surfaces the not-configured message")
        CompanionConfigService.setSearchProviderKind("scrape-ddg")
        let scrapeHandler = controller.makePanelToolHandler()
        try context.expect(scrapeHandler != nil, "Scrape provider produces a dispatch handler")
        let noQuery = await scrapeHandler?("web_search", "not json")
        try context.equal(noQuery, "Error: missing 'query' argument", "Unparseable arguments surface the missing query message")
        CompanionConfigService.setSearchProviderKind("none")

        // Session-approved prefix: alwaysThisSession upgrades the exact
        // command, the retry resolves sessionApproved and builds argv
        // through zsh.
        controller.sessionPermissionMode = .ask
        let sessionIndex = runtime.arguments.count
        let sessionApproval = Task { await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"mkdir session-fixture\"}") }
        for _ in 0..<1000 {
            if controller.approvalRequest != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.equal(controller.approvalRequest?.command, "mkdir session-fixture", "Session approval card created")
        controller.decide(.alwaysThisSession)
        try await waitForProcess(runtime, index: sessionIndex, context)
        runtime.process(sessionIndex).finish(0)
        let sessionResult = await sessionApproval.value
        try context.expect(sessionResult.hasPrefix("exit code "), "Session-approved command runs")
        try context.equal(runtime.arguments.last?.0.first, "/bin/zsh", "Session-approved argv goes through zsh")

        // Foreground promotion: the controlled process never exits, the
        // watchdog promotes it after the inactivity window.
        let promote = Task { await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo promote-fixture\"}") }
        let promoteIndex = runtime.arguments.count
        try await waitForProcess(runtime, index: promoteIndex, context)
        let promoted = await promote.value
        try context.expect(promoted.hasPrefix("command still running after timeout, moved to background. handle:"), "Hung foreground command promoted to background")
        try context.expect(controller.backgroundProcesses.contains { $0.running }, "Promoted handle appears in the background cards")

        await controller.shutdown()
    }

    private static func waitForProcess(_ runtime: AppCommandRuntime, index: Int, _ context: CoverageContext) async throws {
        for _ in 0..<1000 {
            if runtime.arguments.count > index && runtime.process(index).ready { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.expect(false, "Controlled process not created")
    }
}

private final class AppCommandRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [AppCommandProcess] = []
    private var calls: [([String], String)] = []
    var shouldFail = false
    var arguments: [([String], String)] { lock.withLock { calls } }
    func process(_ index: Int) -> AppCommandProcess { lock.withLock { processes[index] } }
    func spawn(_ argv: [String], _ cwd: String) throws -> (any CommandProcess, OutputRingBuffer) {
        if shouldFail { throw AppCommandFailure() }
        let process = AppCommandProcess()
        let buffer = OutputRingBuffer()
        buffer.append(Data("controlled output".utf8))
        lock.withLock { calls.append((argv, cwd)); processes.append(process) }
        return (process, buffer)
    }
}

private final class AppCommandProcess: CommandProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Int32) -> Void)?
    private var terminationCount = 0
    var ready: Bool { lock.withLock { handler != nil } }
    var terminations: Int { lock.withLock { terminationCount } }
    func terminate() { lock.withLock { terminationCount += 1 }; finish(0) }
    func forceKill() { finish(9) }
    func onTermination(_ handler: @escaping @Sendable (Int32) -> Void) { lock.withLock { self.handler = handler } }
    func finish(_ code: Int32) { lock.withLock { handler }?(code) }
}

private struct AppCommandFailure: LocalizedError {
    var errorDescription: String? { "controlled spawn failure" }
}
