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
