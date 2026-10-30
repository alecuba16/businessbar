import AppKit
import BusinessBarCore
import Combine
import Foundation
import UserNotifications
@testable import BusinessBar

@MainActor
enum AppCoverageScenarios {
    static func run(_ context: CoverageContext) async throws {
        let previousDefaults = CompanionConfigService.defaults
        let previousStore = CompanionConfigService.chatProviderStore
        let previousCredentials = CompanionConfigService.credentials
        var secrets: [String: Data] = [:]
        CompanionConfigService.credentials = .init(
            load: { secrets[$0] },
            save: { secrets[$0] = $1 },
            delete: { secrets.removeValue(forKey: $0) }
        )
        let defaults = try context.defaults("companion")
        CompanionConfigService.defaults = defaults
        CompanionConfigService.chatProviderStore = ChatProviderStore(defaults: defaults)
        defer {
            CompanionConfigService.defaults = previousDefaults
            CompanionConfigService.chatProviderStore = previousStore
            CompanionConfigService.credentials = previousCredentials
        }
        var failures: [String] = []
        await run("preferences", failures: &failures) { try preferences(context, defaults: defaults) }
        await run("providers", failures: &failures) { try await AppConfigScenarios.run(context) }
        await run("rewrite", failures: &failures) { try await AppRewriteScenarios.run(context) }
        await run("commands", failures: &failures) { try await commandTools(context) }
        await run("command execution", failures: &failures) { try await AppCommandExecutionScenarios.run(context) }
        await run("conversations", failures: &failures) { try await conversations(context) }
        await run("companion views", failures: &failures) { try await AppCompanionViewScenarios.run(context) }
        await run("services", failures: &failures) { try await AppServiceScenarios.run(context) }
        await run("views", failures: &failures) { try await AppViewScenarios.run(context) }
        await run("status", failures: &failures) { try await AppStatusScenarios.run(context) }
        await run("chat", failures: &failures) { try await AppChatScenarios.run(context) }
        await run("preferences-ui1", failures: &failures) { try await AppPreferencesUI1Scenarios.run(context) }
        await run("preferences-ui2", failures: &failures) { try await AppPreferencesUI2Scenarios.run(context) }
        await run("crash-acp", failures: &failures) { try await AppCrashAcpScenarios.run(context) }
        await run("logging", failures: &failures) { try await AppLoggingScenarios.run(context) }
        if !failures.isEmpty { throw CoverageContext.Failure(description: failures.joined(separator: "\n")) }
    }

    private static func run(_ name: String, failures: inout [String], body: @escaping () async throws -> Void) async {
        let started = Date()
        print("RUN: app \(name)")
        do {
            try await body()
            print("PASS: app \(name) in \(Int(Date().timeIntervalSince(started)))s")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL: app \(name): \(error)")
        }
    }

    private static func preferences(_ context: CoverageContext, defaults: UserDefaults) throws {
        typealias Config = CompanionConfigService
        var announcements = 0
        let subscription = Config.settingsSaved.sink { announcements += 1 }
        defer { subscription.cancel() }
        try context.equal(Config.baseURL().absoluteString, Constants.DefaultValues.companionBaseURL, "Default endpoint")
        Config.setBaseURL(URL(string: "https://coverage.invalid/v1///")!)
        try context.equal(Config.baseURL().absoluteString, "https://coverage.invalid/v1", "Endpoint trailing slashes normalized")
        defaults.set("http://[", forKey: Constants.Defaults.companionBaseURL)
        try context.equal(Config.baseURL().absoluteString, Constants.DefaultValues.companionBaseURL, "Malformed endpoint falls back")
        Config.setModel("")
        try context.equal(Config.chatProviders().count, 0, "Empty model does not seed provider")
        try context.expect(Config.selectedProvider() == nil, "No provider without configuration")
        try context.expect(Config.selectedModel() == nil, "No model without configuration")
        try context.expect(Config.selectedModelProfile() == nil, "No legacy profile without configuration")
        try context.expect(!Config.isConfigured(), "Empty setup is not configured")
        try context.expect(Config.makeClient() == nil, "Empty setup cannot build client")
        try context.expect(Config.makeClient(forModelID: UUID()) == nil, "Unknown rewrite model cannot build client")
        Config.setSystemPrompt("Use exact language")
        try context.equal(Config.systemPrompt(), "Use exact language", "Prompt persistence")
        Config.setSearchProviderKind("scrape-bing")
        Config.setSearchProviderKind("none")
        try context.equal(Config.searchProviderKind(), "none", "Search disabled")
        try context.equal(Config.lastSearchProviderKind(), "scrape-bing", "Disabling preserves previous search provider")
        try context.expect(Config.makeSearchProvider() == nil, "Disabled search has no provider")
        try context.expect(Config.searchToolHandler() == nil, "Disabled search has no handler")
        try context.equal(Config.searchTools().count, 0, "Disabled search exposes no tools")
        for kind in ["scrape-ddg", "scrape-bing", "scrape-google-news"] {
            Config.setSearchProviderKind(kind)
            try context.expect(Config.makeSearchProvider() != nil, "Scraped provider resolves without network: \(kind)")
        }
        Config.setSearchProviderKind("none")
        Config.setCustomSearchEndpoint(nil)
        try context.expect(Config.customSearchEndpoint() == nil, "Empty custom endpoint")
        Config.setCustomSearchEndpoint(URL(string: "https://coverage.invalid/search")!)
        try context.equal(Config.customSearchEndpoint()?.host, "coverage.invalid", "Custom endpoint persistence")
        Config.setCustomSearchEndpointText("https://coverage.invalid/?q={query}")
        try context.equal(defaults.string(forKey: Constants.Defaults.companionCustomSearchEndpoint), "https://coverage.invalid/?q={query}", "Template endpoint stored without encoding")
        Config.setCustomSearchHeaderName("X-Test")
        try context.equal(Config.customSearchHeaderName(), "X-Test", "Header name persistence")
        Config.setGitHubSearchEnabled(false)
        try context.expect(!Config.githubSearchEnabled(), "GitHub disabled persistence")
        try context.expect(Config.makeGitHubSearchProvider() == nil, "Disabled GitHub has no provider")
        Config.setAdhocChatEffort("")
        try context.expect(Config.chatEffortOverride() == nil, "Blank ad hoc effort inherits")
        Config.setAdhocChatEffort("high")
        try context.equal(Config.chatEffortOverride(), "high", "Ad hoc effort persistence")
        Config.setChatInputExpanded(true)
        try context.expect(Config.chatInputExpanded(), "Input expansion persistence")
        Config.setReasoningEnabled(true)
        Config.setReasoningEffort("low")
        try context.expect(Config.reasoningEnabled(), "Reasoning enabled persistence")
        try context.equal(Config.reasoningEffort(), "low", "Reasoning effort persistence")
        Config.setHistoryMaxAgeDays(0)
        Config.setHistoryMaxSessions(0)
        try context.equal(Config.historyMaxAgeDays(), 0, "Unlimited history age")
        try context.equal(Config.historyMaxSessions(), 0, "Unlimited history count")
        Config.setACPCommand("coverage-agent")
        Config.setACPArguments(["--stdio", "fixture"])
        try context.equal(Config.acpCommand(), "coverage-agent", "Agent command persistence")
        try context.equal(Config.acpArguments(), ["--stdio", "fixture"], "Agent arguments persistence")
        Config.setCommandToolsEnabled(true)
        try context.expect(Config.commandToolsEnabled(), "Command tools persistence")
        Config.setCommandPermissionMode(.deny)
        try context.equal(Config.commandPermissionMode(), .deny, "Command permission persistence")
        for category in CommandCategory.allCases {
            Config.setCommandCategoryMode(.ask, for: category)
            try context.equal(Config.commandCategoryMode(category), .ask, "Category override persistence")
            Config.setCommandCategoryMode(nil, for: category)
            try context.expect(Config.commandCategoryMode(category) == nil, "Category override removal")
        }
        Config.setCommandAllowedPrefixes(["git status"])
        Config.setCommandDeniedPrefixes(["rm *"])
        try context.equal(Config.commandAllowedPrefixes(), ["git status"], "Allowed prefixes persistence")
        try context.equal(Config.commandDeniedPrefixes(), ["rm *"], "Denied prefixes persistence")
        _ = Config.commandPermissionSettings()
        Config.setCommandDefaultWorkingDir("/does-not-exist-businessbar-coverage")
        try context.equal(Config.commandDefaultWorkingDir(), NSHomeDirectory(), "Missing workspace falls back to home")
        try context.equal(Config.effortOptions(forModel: nil), Config.effortLevels, "No model uses default vocabulary")
        let model = ChatModel(name: "Fixture", model: "gpt-5-fixture", effortOptions: ["brief", "deep"])
        try context.equal(Config.effortOptions(forModel: model), ["brief", "deep"], "Pinned effort vocabulary wins")
        try context.equal(Config.knownModelEffortOptions("o3"), ["low", "medium", "high"], "Known model vocabulary")
        try context.equal(Config.effortOptions(forModelID: UUID()), Config.effortLevels, "Stale model vocabulary falls back")
        try context.expect(announcements > 10, "Preference writes publish change announcements")
    }

    private static func commandTools(_ context: CoverageContext) async throws {
        let root = try context.temporaryDirectory("commands")
        try "one\ntwo\nthree".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("binary"))
        try "hidden".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "child".write(to: root.appendingPathComponent("nested/child"), atomically: true, encoding: .utf8)
        CompanionConfigService.setCommandDefaultWorkingDir(root.path)
        CompanionConfigService.setCommandPermissionMode(.deny)
        var pickedURL: URL? = root
        var notifications: [UNNotificationRequest] = []
        let controller = CommandToolController(presentation: .init(chooseWorkspace: { pickedURL }, notify: { notifications.append($0) }))
        controller.pickWorkspace()
        try context.equal(controller.workspaceRoot, root.path, "Injected workspace picker selection")
        pickedURL = nil
        controller.pickWorkspace()
        try context.equal(controller.workspaceRoot, root.path, "Picker cancellation preserves workspace")
        var categories: Set<UNNotificationCategory> = []
        CommandToolController.registerNotificationCategory { categories = $0 }
        try context.equal(categories.first?.identifier, "companion.backgroundCommand", "Background notification category registered")
        controller.postCompletionNotification(command: "fixture command", exitCode: 7)
        try context.equal(notifications.first?.content.body, "fixture command\nexit code 7", "Completion notification content")
        controller.isPanelVisible = { true }
        controller.postCompletionNotification(command: "hidden", exitCode: 0)
        try context.equal(notifications.count, 1, "Visible panel suppresses system notification")
        try context.equal(controller.effectiveWorkspaceRoot, root.path, "Default workspace")
        controller.beginSession(UUID())
        try context.equal(controller.sessionPermissionMode, .deny, "Session gets configured mode")
        let cases: [(String, String, String)] = [
            ("read_file", "{\"path\":\"note.txt\"}", "one\ntwo\nthree"),
            ("read_file", "{\"path\":\"note.txt\",\"offset\":2,\"limit\":1}", "two"),
            ("read_file", "{\"path\":\"note.txt\",\"offset\":99}", ""),
            ("read_file", "{\"path\":\"missing\"}", "error: file not found: missing"),
            ("read_file", "{\"path\":\"binary\"}", "error: file is not valid UTF-8 text"),
            ("read_file", "{\"path\":\"../escape\"}", "error: path is outside the workspace folder"),
            ("list_files", "{\"path\":\"missing\"}", "error: folder not found: missing"),
            ("list_files", "{\"path\":\"note.txt\"}", "error: not a folder: note.txt"),
            ("list_files", "{\"path\":\"../escape\"}", "error: path is outside the workspace folder"),
            ("run_command", "{}", "error: run_command needs a command string"),
            ("read_background_output", "{}", "error: invalid handle"),
            ("stop_background_process", "{}", "error: invalid handle"),
            ("unknown", "{}", "error: unknown tool unknown"),
            ("unknown", "[", "error: could not parse tool arguments"),
            ("list_background_processes", "{}", "no background processes")
        ]
        for (name, json, expected) in cases {
            let result = await controller.handleToolCall(name: name, argumentsJSON: json)
            try context.equal(result, expected, "Command tool \(name): \(json)")
        }
        let listed = await controller.handleToolCall(name: "list_files", argumentsJSON: "{}")
        try context.equal(listed, "binary\nnested/\nnote.txt", "Listing sorted and hidden entries omitted")
        let recursive = await controller.handleToolCall(name: "list_files", argumentsJSON: "{\"recursive\":true}")
        try context.expect(recursive.contains("nested/child"), "Recursive listing visits child directories")
        let denied = await controller.handleToolCall(name: "run_command", argumentsJSON: "{\"command\":\"echo fixture\"}")
        try context.expect(denied.hasPrefix("denied:"), "Denied mode never launches a process")
        let absentID = UUID()
        let absent = await controller.handleToolCall(name: "read_background_output", argumentsJSON: "{\"handle\":\"\(absentID)\"}")
        try context.expect(absent.hasPrefix("error: process no longer exists"), "Unknown process output")
        let stopped = await controller.handleToolCall(name: "stop_background_process", argumentsJSON: "{\"handle\":\"\(absentID)\"}")
        try context.equal(stopped, "error: process not found or already exited", "Unknown process stop")
        var decisionCalled = false
        controller.approvalRequest = CommandApprovalRequest(command: "fixture", reason: .unknownCommand, category: .unknown, targets: [], workspaceRoot: root.path, completion: { decision in decisionCalled = decision == .denied })
        controller.denyPendingApproval()
        try context.expect(decisionCalled && controller.approvalRequest == nil, "Pending approval is denied and cleared")
        controller.decide(.allowOnce)
        for decision in [CommandApprovalRequest.Decision.allowOnce, .alwaysThisSession, .alwaysAllowPersistent, .denied] {
            var completionCount = 0
            controller.approvalRequest = CommandApprovalRequest(command: "fixture-prefix", reason: .unknownCommand, category: .unknown, targets: [], workspaceRoot: root.path, completion: { received in
                if received == decision { completionCount += 1 }
            })
            controller.decide(decision)
            try context.equal(completionCount, 1, "Approval decision resumes exactly once")
            try context.expect(controller.approvalRequest == nil, "Approval decision clears pending card")
        }
        try context.expect(CompanionConfigService.commandAllowedPrefixes().contains("fixture-prefix"), "Persistent approval writes prefix")
        CompanionConfigService.setCommandToolsEnabled(false)
        try context.expect(controller.makePanelToolHandler() == nil, "Disabled command tools have no handler")
        CompanionConfigService.setCommandToolsEnabled(true)
        let handler = controller.makePanelToolHandler()
        try context.expect(handler != nil, "Enabled command tools produce panel handler")
        let toolError = await handler?("unknown", "{}")
        try context.equal(toolError, "error: unknown tool unknown", "Panel handler routes command tools")
        controller.workspaceRoot = root.appendingPathComponent("nested").path
        try context.equal(controller.effectiveWorkspaceRoot, controller.workspaceRoot, "Session workspace overrides default")
        controller.endSession()
        try context.expect(controller.workspaceRoot == nil, "Ending session clears workspace")
        let pending = await controller.drainPendingResults()
        try context.expect(pending.isEmpty, "Empty registry has no results")
        await controller.shutdown()
    }

    private static func conversations(_ context: CoverageContext) async throws {
        let disk = ChatSessionStore(directoryURL: try context.temporaryDirectory("chat"))
        let store = ChatStore(sessionStore: disk)
        var sessionChanges = 0
        store.onSessionChanged = { _ in sessionChanges += 1 }
        try context.expect(!store.hasClosableSession, "Initial chat is empty")
        store.closeAndStartNewSession()
        store.restoreMostRecentSession()
        store.load(sessionID: UUID())
        store.send("", client: CoverageChatClient(events: []))
        try context.expect(store.messages.isEmpty, "Empty prompt ignored")
        store.send("  first line\nsecond line", client: CoverageChatClient(events: [.thinkingDelta("reason"), .toolCallRequested(name: "web_search", argumentsJSON: "{}"), .delta("partial"), .finished(fullText: "answer")]))
        try context.expect(store.isStreaming, "Send marks streaming synchronously")
        store.send("duplicate", client: CoverageChatClient(events: []))
        store.load(sessionID: UUID())
        try context.expect(store.editLastUserPrompt() == nil, "Cannot edit during stream")
        try await settle(store, context)
        try context.equal(store.messages.map(\.content), ["  first line\nsecond line", "answer"], "Stream commits one assistant response")
        try context.equal(store.messages.last?.thinking, "reason", "Thinking stored separately")
        try context.equal(store.sessionHistory.first?.title, "first line", "Session title uses trimmed first line")
        try context.expect(store.streamingText == nil && store.activityLabel.isEmpty, "Streaming UI cleared")
        guard let savedID = store.currentSessionID else { throw CoverageContext.Failure(description: "Chat missing persisted ID") }
        try context.equal(disk.load(id: savedID)?.messages.count, 2, "Conversation persisted")
        store.startNewSession()
        store.restoreMostRecentSession()
        try context.equal(store.currentSessionID, savedID, "Most recent session restored")
        try context.equal(store.editLastUserPrompt(), "  first line\nsecond line", "Edit restores prompt and removes its response")
        try context.expect(store.messages.isEmpty, "Edit truncates conversation")
        store.send("retry", client: CoverageChatClient(events: [.failed("fixture failure")]))
        try await settle(store, context)
        try context.equal(store.errorMessage, "fixture failure", "Failure shown")
        store.retryLast(clientProvider: { CoverageChatClient(events: [.delta("fallback"), .finished(fullText: "")]) })
        try await settle(store, context)
        try context.equal(store.messages.map(\.content), ["retry", "fallback"], "Retry does not duplicate prompt and empty finished uses deltas")
        store.send("cancelled", client: CoverageChatClient(events: [.delta("partial cancellation"), .cancelled]))
        try await settle(store, context)
        try context.equal(store.messages.last?.content, "partial cancellation", "Cancelled response preserves partial text")
        store.send("throws", client: CoverageChatClient(events: [], failure: CoverageChatError()))
        try await settle(store, context)
        try context.expect(store.errorMessage != nil, "Thrown stream error shown")
        store.retryLast(clientProvider: { nil })
        try context.expect(store.errorMessage == nil, "Unavailable retry clears displayed error")
        store.closeAndStartNewSession()
        try context.expect(!store.hasClosableSession, "Closing starts clean chat")
        store.load(sessionID: savedID)
        store.deleteSession(id: savedID)
        try context.expect(store.currentSessionID == nil, "Deleting current session resets chat")
        store.deleteSessionsOlderThan(days: 1)
        store.clear()
        store.cancel()
        store.deleteAllSessions()
        try context.expect(store.sessionHistory.isEmpty && disk.loadAll().isEmpty, "Delete all clears persistence and history")
        try context.expect(sessionChanges >= 5, "Session lifecycle callbacks emitted")
    }

    private static func settle(_ store: ChatStore, _ context: CoverageContext) async throws {
        for _ in 0..<1000 {
            if !store.isStreaming { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.expect(false, "Chat stream did not settle")
    }
}

private struct CoverageChatError: LocalizedError {
    var errorDescription: String? { "controlled stream failure" }
}

private struct CoverageChatClient: LLMClient {
    let name = "Coverage fixture"
    let events: [CompanionEvent]
    var failure: CoverageChatError?

    func stream(messages: [ChatMessage], onToolCall: ((String, String) async -> String)?, reasoningEffortOverride: String?) async -> AsyncThrowingStream<CompanionEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }
}
