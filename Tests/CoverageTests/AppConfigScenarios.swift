import BusinessBarCore
import Foundation
@testable import BusinessBar

@MainActor
enum AppConfigScenarios {
    static func run(_ context: CoverageContext) async throws {
        typealias Config = CompanionConfigService
        let defaults = try context.defaults("provider-config")
        let previousDefaults = Config.defaults
        let previousStore = Config.chatProviderStore
        Config.defaults = defaults
        Config.chatProviderStore = ChatProviderStore(defaults: defaults)
        defer {
            Config.defaults = previousDefaults
            Config.chatProviderStore = previousStore
        }
        Config.setModel("")
        Config.setSearchProviderKind("none")
        try context.equal(Config.apiKey(), "", "Absent API key reads empty")
        try Config.setAPIKey("legacy-token")
        try context.equal(Config.apiKey(), "legacy-token", "API credential round trip")
        try Config.setBraveKey("brave-fixture")
        try Config.setTavilyKey("tavily-fixture")
        try Config.setCustomSearchKey("custom-fixture")
        try Config.setGitHubSearchKey("github-fixture")
        try context.equal(Config.braveKey(), "brave-fixture", "Brave credential round trip")
        try context.equal(Config.tavilyKey(), "tavily-fixture", "Tavily credential round trip")
        try context.equal(Config.customSearchKey(), "custom-fixture", "Custom credential round trip")
        try context.equal(Config.githubSearchKey(), "github-fixture", "GitHub credential round trip")
        try Config.setCustomHeaders([(name: "X-Gateway", value: "legacy-header")])
        try context.equal(Config.customHeaders().first?.value, "legacy-header", "Legacy headers round trip")
        try Config.setCustomSearchHeaders([(name: "X-Search", value: "search-header")])
        try context.equal(Config.customSearchHeaders().first?.name, "X-Search", "Search headers round trip")
        try Config.setCustomHeaders([(name: "X-Gateway", value: "legacy-header")])
        Config.setModel("o3-fixture")
        Config.setBaseURL(URL(string: "https://coverage.invalid/v1/")!)
        Config.setSystemPrompt("Legacy prompt")
        Config.setReasoningEnabled(true)
        Config.setReasoningEffort("high")
        let seeded = Config.chatProviders()
        try context.equal(seeded.count, 1, "Legacy single model seeds one provider")
        guard let provider = seeded.first, let model = provider.models.first else {
            throw CoverageContext.Failure(description: "Missing seeded provider model")
        }
        try context.equal(Config.providerAPIKey(id: provider.id), "legacy-token", "Seeding migrates credential")
        try context.equal(Config.providerHeaders(id: provider.id).first?.value, "legacy-header", "Seeding migrates headers")
        try context.equal(model.systemPrompt, "Legacy prompt", "Seeding migrates prompt")
        try context.equal(model.reasoningEffort, "high", "Seeding migrates reasoning effort")
        try context.equal(Config.selectedModel()?.model.id, model.id, "Seed model selected")
        try context.equal(Config.selectedProvider()?.id, provider.id, "Seed provider selected")
        try context.equal(Config.backend(), .openai, "Remote model uses OpenAI backend")
        try context.expect(Config.isOpenAIConfigured() && Config.isConfigured(), "Key plus model configures backend")
        try context.expect(!Config.isACPConfigured(), "Remote provider is not agent")
        try context.expect(Config.makeClient() is OpenAICompatClient, "Configured remote client builds")
        try context.expect(Config.makeChatClient() is OpenAICompatClient, "Configured chat client builds")
        try context.expect(Config.makeClient(forModelID: model.id) is OpenAICompatClient, "Pinned rewrite client builds")
        try context.equal(Config.selectedModelProfile()?.model, model.model, "Legacy profile flattens selected model")
        try context.equal(Config.effortOptions(forModelID: model.id), ["low", "medium", "high"], "Model ID resolves effort vocabulary")
        Config.setSelectedModelProfileID(provider.id)
        try context.equal(Config.selectedModel()?.model.id, model.id, "Legacy provider selection resolves first model")
        Config.setSelectedModelProfileID(UUID())
        try context.equal(Config.selectedModel()?.model.id, model.id, "Stale selection falls back")
        defaults.set("not-a-uuid", forKey: Constants.Defaults.companionSelectedModelProfile)
        try context.expect(Config.selectedProvider() == nil, "Invalid provider selection does not resolve")
        try context.equal(Config.selectedModel()?.model.id, model.id, "Invalid model selection falls back")
        Config.setSelectedModelProfileID(model.id)
        try await Config.ensureLocalServerIfNeeded()
        try await Config.ensureLocalServer(forModelID: model.id)
        Config.setCommandToolsEnabled(true)
        let names = Config.chatToolSchemas().compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        try context.expect(names.contains("run_command") && names.contains("read_file"), "Remote chat advertises enabled command tools")
        Config.setCommandToolsEnabled(false)
        try context.expect(Config.chatToolSchemas().isEmpty, "Disabled commands and search expose no schemas")
        for kind in ["brave", "tavily", "custom"] {
            Config.setSearchProviderKind(kind)
            Config.setCustomSearchEndpoint(URL(string: "https://coverage.invalid/search")!)
            try context.expect(Config.makeSearchProvider() != nil, "Configured \(kind) search resolves without request")
        }
        Config.setGitHubSearchEnabled(true)
        try context.expect(Config.makeGitHubSearchProvider() != nil, "GitHub token enables provider")
        try context.equal(Config.searchTools().count, 2, "Web and GitHub schemas merged")
        guard let handler = Config.searchToolHandler() else { throw CoverageContext.Failure(description: "Missing search handler") }
        let unknown = await handler("unknown", "{}")
        try context.equal(unknown, "Error: unknown tool unknown", "Unknown tool rejected without request")
        let missing = await handler("web_search", "not-json")
        try context.equal(missing, "Error: missing 'query' argument", "Malformed search rejected without request")
        Config.setSearchProviderKind("none")
        let githubOnly = Config.searchToolHandler()!
        let disabled = await githubOnly("web_search", "{\"query\":\"fixture\"}")
        try context.equal(disabled, "Error: web_search is not configured", "Missing search provider rejected")
        Config.setGitHubSearchEnabled(false)
        Config.setBackend(.acp)
        Config.setACPCommand("coverage-agent-never-launched")
        Config.setACPArguments(["--fixture"])
        let migrated = Config.chatProviders()
        guard let agent = migrated.first(where: { $0.kind == .acpAgent }) else { throw CoverageContext.Failure(description: "Agent migration missing") }
        try context.equal(Config.chatProviders().filter { $0.kind == .acpAgent }.count, 1, "Agent migration idempotent")
        try context.equal(Config.selectedACPProvider()?.id, agent.id, "Migrated agent selected")
        try context.equal(Config.backend(), .acp, "Agent selection drives backend")
        try context.expect(Config.selectedModel() == nil, "Agent has no selected chat model")
        try context.expect(Config.isACPConfigured() && Config.isConfigured(), "Configured agent gate")
        try context.expect(Config.makeClient() is ACPAgentClient, "Agent client constructed without starting process")
        try context.expect(Config.makeChatClient() is ACPAgentClient, "Agent chat uses cached client")
        try context.expect(Config.makeClient(forModelID: nil) is ACPAgentClient, "Unpinned rewrite uses agent")
        try context.expect(Config.chatToolSchemas().isEmpty, "Agent manages its own tools")
        await Config.shutdownACP()
        Config.shutdownACPSync()
        Config.setSelectedModelProfileID(model.id)
        Config.deleteModel(id: UUID(), in: UUID())
        Config.deleteModel(id: model.id, in: provider.id)
        try context.expect(Config.chatProviderStore.load().first(where: { $0.id == provider.id })?.models.isEmpty == true, "Deleting model preserves provider")
        Config.deleteProvider(id: provider.id)
        try context.expect(!Config.chatProviderStore.load().contains(where: { $0.id == provider.id }), "Deleting provider updates storage")
        try context.equal(Config.providerAPIKey(id: provider.id), "", "Deleting provider removes credential")
        Config.deleteAPIKey()
        try context.equal(Config.apiKey(), "", "Deleting legacy credential")
        try await fetchModels(context)
        try configMigration(context, defaults: defaults)
    }

    private static func configMigration(_ context: CoverageContext, defaults: UserDefaults) throws {
        typealias Config = CompanionConfigService
        // History retention setters.
        Config.setHistoryMaxAgeDays(30)
        try context.equal(Config.historyMaxAgeDays(), 30, "History age limit round trip")
        Config.setHistoryMaxSessions(120)
        try context.equal(Config.historyMaxSessions(), 120, "History session limit round trip")
        Config.setAdhocChatEffort("high")
        try context.equal(Config.adhocChatEffort(), "high", "Ad-hoc chat effort round trip")
        Config.setAdhocChatEffort("")
        try context.equal(Config.adhocChatEffort(), "", "Ad-hoc effort reset to profile default")

        // Legacy ACP migration: the legacy backend key plus a stored ACP
        // command seed the agent provider exactly once, then selection owns
        // the backend and the legacy key is cleared. Fresh suite required:
        // the outer scenario already seeded an agent into the shared suite,
        // which would trip the exactly-once guard and leave the stale
        // selection pointing at a deleted model.
        Config.setModel("")
        let legacyDefaults = try context.defaults("legacy-acp-migration")
        let legacyStore = ChatProviderStore(defaults: legacyDefaults)
        let previousConfigDefaults = Config.defaults
        let previousStore = Config.chatProviderStore
        Config.defaults = legacyDefaults
        Config.chatProviderStore = legacyStore
        defer {
            Config.defaults = previousConfigDefaults
            Config.chatProviderStore = previousStore
        }
        Config.setACPCommand("fixture-agent")
        Config.setACPArguments(["--stdio"])
        Config.setBackend(.acp)
        let legacy = Config.chatProviders()
        try context.expect(legacy.contains { $0.kind == .acpAgent }, "Legacy ACP preset seeded from backend key and command")
        let seededAgain = Config.chatProviders()
        try context.equal(seededAgain.count, legacy.count, "Legacy seeding happens exactly once")
        try context.expect(Config.selectedProvider()?.kind == .acpAgent, "Seeded agent becomes the selection")
        Config.defaults = previousConfigDefaults
        Config.chatProviderStore = previousStore

        // Local MLX provider upsert: the provider mirrors every downloaded
        // catalog model, active first, so downloads land in chat pickers.
        Config.setBackend(.openai)
        let localDefaults = try context.defaults("local-mlx-provider")
        let localStore = ChatProviderStore(defaults: localDefaults)
        let previousMlxDefaults = Config.defaults
        Config.defaults = localDefaults
        Config.chatProviderStore = localStore
        defer {
            Config.defaults = previousMlxDefaults
            Config.chatProviderStore = previousStore
        }
        let localHome = try context.temporaryDirectory("local-mlx-provider-home").path
        try context.expect(Config.upsertLocalMLXProvider(home: localHome) == nil, "Nothing downloaded yields no provider")
        // Two downloaded fixtures: the curated entry and a custom one. The
        // curated id drives the mirror with real catalog data; the custom
        // entry proves custom models land too.
        let curatedID = MLXModelCatalog.entries[0].id
        let fixtureDirectory = MLXModelCatalog.cacheDirectory(modelID: curatedID, home: localHome)
            .appendingPathComponent("snapshots/fixture")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        for file in MLXModelCatalog.requiredFiles {
            FileManager.default.createFile(atPath: fixtureDirectory.appendingPathComponent(file).path, contents: Data("fixture".utf8))
        }
        let customID = "mlx-community/Fixture-Custom-Provider-4bit"
        let customDirectory = MLXModelCatalog.cacheDirectory(modelID: customID, home: localHome)
            .appendingPathComponent("snapshots/fixture")
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        for file in MLXModelCatalog.requiredFiles {
            FileManager.default.createFile(atPath: customDirectory.appendingPathComponent(file).path, contents: Data("fixture".utf8))
        }
        _ = MLXModelCatalog.addCustomEntry(
            MLXModelCatalog.Entry(id: customID, displayName: "Fixture Custom Provider", sizeBytes: 1_000, ramBytes: 2_000, kind: .text, reasoning: nil),
            defaults: localDefaults
        )
        MLXServerConfig.setActiveModelID(customID, defaults: localDefaults)
        guard let first = Config.upsertLocalMLXProvider(home: localHome) else {
            throw CoverageContext.Failure(description: "Upserting the local MLX provider failed")
        }
        try context.equal(first.name, "Local (MLX)", "Upserted provider keeps its display name")
        try context.expect(first.isLocalMLXProvider, "Upserted provider is the local kind")
        try context.equal(first.models.count, 2, "Both downloaded models mirror into the provider")
        try context.equal(first.models.first?.model, customID, "Active model sorts first")
        try context.expect(first.models.contains { $0.model == curatedID }, "Curated download appears alongside the custom one")
        guard let updated = Config.upsertLocalMLXProvider(home: localHome) else {
            throw CoverageContext.Failure(description: "Second upsert failed")
        }
        try context.equal(updated.id, first.id, "Repeated upsert preserves provider identity")
        try context.equal(updated.models.map(\.model), first.models.map(\.model), "Repeated upsert keeps the mirrored rows")
        let stored = localStore.load()
        try context.expect(stored.contains { $0.kind == .localMLX }, "Local provider persisted through upsert")
        // Deleting the last servable model drops the provider and releases
        // the port by clearing the active choice.
        try? FileManager.default.removeItem(at: customDirectory)
        MLXModelCatalog.removeCustomEntry(id: customID, defaults: localDefaults)
        MLXServerConfig.setActiveModelID(nil, defaults: localDefaults)
        guard let remaining = Config.upsertLocalMLXProvider(home: localHome) else {
            throw CoverageContext.Failure(description: "Post-delete upsert should keep the curated model")
        }
        try context.equal(remaining.models.map(\.model), [curatedID], "Delete re-mirrors without the removed model")
        try? FileManager.default.removeItem(at: fixtureDirectory)
        try context.expect(Config.upsertLocalMLXProvider(home: localHome) == nil, "Empty catalog drops the provider")
        try context.expect(!localStore.load().contains { $0.kind == .localMLX }, "Empty catalog removes the stored provider")
    }

    private static func fetchModels(_ context: CoverageContext) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppModelURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = ChatProvider(name: "Fixture", baseURL: "https://coverage.invalid/v1///", models: [])
        try CompanionConfigService.setProviderAPIKey(provider.id, "fixture-token")
        try CompanionConfigService.setProviderHeaders(id: provider.id, [(name: "X-Coverage", value: "injected")])
        let models = try await CompanionConfigService.fetchRemoteModels(provider: provider, session: session)
        try context.equal(models.map(\.id), ["fixture-model"], "Injected transport model list")
        try context.expect(models.first?.supportsReasoning == true, "Remote model capability propagated")
        try context.equal(AppModelURLProtocol.lastRequest?.url?.path, "/v1/models", "Model endpoint normalized")
        try context.equal(AppModelURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token", "Provider credential passed to request")
        try context.equal(AppModelURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Coverage"), "injected", "Provider custom header passed to request")
    }
}

private final class AppModelURLProtocol: URLProtocol, @unchecked Sendable {
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"data\":[{\"id\":\"fixture-model\",\"reasoning\":true}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
