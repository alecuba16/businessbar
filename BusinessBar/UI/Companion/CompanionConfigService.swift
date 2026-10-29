import BusinessBarCore
import Combine
import Foundation

// MARK: - CompanionConfigService

/// Owns the companion backend configuration: base URL, model and API key.
/// The API key lives in the Keychain (never UserDefaults); the rest is
/// stored in UserDefaults through `Constants.Defaults` keys.
///
/// `makeClient()` returns a fresh client per call so config edits take
/// effect on the next request without invalidating in-flight streams.
enum CompanionConfigService {
    static let keychainKey = "com.businessbar.companion.apiKey"

    /// Fires after any companion setting write, so mounted views can
    /// re-read gates that depend on Preferences state.
    static var settingsSaved: AnyPublisher<Void, Never> { SettingsSavedBus.publisher }
    static let braveKeychainKey = "com.businessbar.companion.braveKey"
    static let tavilyKeychainKey = "com.businessbar.companion.tavilyKey"
    static let customSearchKeychainKey = "com.businessbar.companion.customSearchKey"
    static let customHeadersKeychainKey = "com.businessbar.companion.customHeaders"
    static let githubSearchKeychainKey = "com.businessbar.companion.githubSearchKey"

    // MARK: - Backend selection

    /// Which LLM backend the companion uses.
    enum Backend: String {
        case openai
        case acp
    }

    static func backend() -> Backend {
        Backend(rawValue: UserDefaults.standard.string(forKey: Constants.Defaults.companionBackend) ?? "") ?? .openai
    }

    static func setBackend(_ backend: Backend) {
        UserDefaults.standard.set(backend.rawValue, forKey: Constants.Defaults.companionBackend)
        SettingsSavedBus.announce()
    }

    // MARK: - Storage

    static func baseURL() -> URL {
        let raw = UserDefaults.standard.string(forKey: Constants.Defaults.companionBaseURL)
            ?? Constants.DefaultValues.companionBaseURL
        // Accept both "https://host/v1" and "https://host/v1/" spellings.
        var normalized = raw
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return URL(string: normalized) ?? URL(string: Constants.DefaultValues.companionBaseURL)!
    }

    static func setBaseURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: Constants.Defaults.companionBaseURL)
    }

    static func model() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionModel)
            ?? Constants.DefaultValues.companionModel
    }

    static func setModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: Constants.Defaults.companionModel)
    }

    static func systemPrompt() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionSystemPrompt) ?? ""
    }

    static func setSystemPrompt(_ prompt: String) {
        UserDefaults.standard.set(prompt, forKey: Constants.Defaults.companionSystemPrompt)
    }

    // MARK: - Keychain

    static func apiKey() -> String {
        guard let data = try? KeychainHelper.load(key: keychainKey) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func setAPIKey(_ key: String) throws {
        try KeychainHelper.save(key: keychainKey, data: Data(key.utf8))
        SettingsSavedBus.announce()
    }

    static func deleteAPIKey() {
        try? KeychainHelper.delete(key: keychainKey)
    }

    // MARK: - Search provider

    static func searchProviderKind() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionSearchProvider)
            ?? Constants.DefaultValues.companionSearchProvider
    }

    static func setSearchProviderKind(_ kind: String) {
        UserDefaults.standard.set(kind, forKey: Constants.Defaults.companionSearchProvider)
        // Remember the last real choice so toggling the tool off and back
        // on restores it instead of resetting to a default.
        if kind != "none" {
            UserDefaults.standard.set(kind, forKey: Constants.Defaults.companionLastSearchProvider)
        }
        SettingsSavedBus.announce()
    }

    /// The kind the web search tool should return to when re-enabled:
    /// the last used kind, or the scraped default that needs no key.
    static func lastSearchProviderKind() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionLastSearchProvider)
            ?? "scrape-ddg"
    }

    static func customSearchEndpoint() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: Constants.Defaults.companionCustomSearchEndpoint),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static func setCustomSearchEndpoint(_ url: URL?) {
        UserDefaults.standard.set(url?.absoluteString ?? "", forKey: Constants.Defaults.companionCustomSearchEndpoint)
        SettingsSavedBus.announce()
    }

    /// Persists the endpoint text as typed. Template URLs contain `{query}`
    /// which `URL(string:)` percent-encodes, so the raw string is the only
    /// faithful roundtrip; `customSearchEndpoint()` still parses it into a URL.
    static func setCustomSearchEndpointText(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: Constants.Defaults.companionCustomSearchEndpoint)
        SettingsSavedBus.announce()
    }

    static func customSearchHeaderName() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionCustomSearchHeaderName) ?? ""
    }

    static func setCustomSearchHeaderName(_ name: String) {
        UserDefaults.standard.set(name, forKey: Constants.Defaults.companionCustomSearchHeaderName)
    }

    // MARK: - Search keys (Keychain)

    static func braveKey() -> String {
        keychainString(braveKeychainKey)
    }

    static func setBraveKey(_ key: String) throws {
        try KeychainHelper.save(key: braveKeychainKey, data: Data(key.utf8))
        SettingsSavedBus.announce()
    }

    static func tavilyKey() -> String {
        keychainString(tavilyKeychainKey)
    }

    static func setTavilyKey(_ key: String) throws {
        try KeychainHelper.save(key: tavilyKeychainKey, data: Data(key.utf8))
        SettingsSavedBus.announce()
    }

    static func customSearchKey() -> String {
        keychainString(customSearchKeychainKey)
    }

    static func setCustomSearchKey(_ key: String) throws {
        try KeychainHelper.save(key: customSearchKeychainKey, data: Data(key.utf8))
        SettingsSavedBus.announce()
    }

    /// Extra headers for the custom search endpoint, Keychain-stored as
    /// JSON like provider headers, because values can be tokens.
    static func customSearchHeaders() -> [(name: String, value: String)] {
        guard let data = try? KeychainHelper.load(key: customHeadersKeychainKey),
              let raw = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return [] }
        return raw.compactMap { pair in
            guard let name = pair["name"], let value = pair["value"] else { return nil }
            return (name, value)
        }
    }

    static func setCustomSearchHeaders(_ headers: [(name: String, value: String)]) throws {
        let raw = headers.map { ["name": $0.name, "value": $0.value] }
        guard let data = try? JSONEncoder().encode(raw) else {
            throw CocoaError(.coderInvalidValue)
        }
        try KeychainHelper.save(key: customHeadersKeychainKey, data: data)
        SettingsSavedBus.announce()
    }

    // MARK: - GitHub code search

    /// GitHub search token (personal access token) from the Keychain.
    static func githubSearchKey() -> String {
        keychainString(githubSearchKeychainKey)
    }

    static func setGitHubSearchKey(_ key: String) throws {
        try KeychainHelper.save(key: githubSearchKeychainKey, data: Data(key.utf8))
        SettingsSavedBus.announce()
    }

    /// User switch for the github_search tool. Off by default; the tool
    /// is only advertised when this is on AND a token exists, so the model
    /// can never see a tool that cannot run.
    static func githubSearchEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Constants.Defaults.companionGitHubSearchEnabled)
    }

    static func setGitHubSearchEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Constants.Defaults.companionGitHubSearchEnabled)
        SettingsSavedBus.announce()
    }

    private static func keychainString(_ key: String) -> String {
        guard let data = try? KeychainHelper.load(key: key) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Providers and models

    /// Shared store for providers (endpoint + models + effort).
    static let chatProviderStore = ChatProviderStore()

    /// Loads providers, migrating a stored legacy `[ModelProfile]` blob once,
    /// then seeding from the legacy single-model config when both stores are
    /// empty so existing users keep their working setup. Legacy global fields
    /// (system prompt, reasoning, effort, headers) attach to the seeded or
    /// migrated models exactly once so removing the old backend section
    /// loses nothing.
    static func chatProviders() -> [ChatProvider] {
        let stored = chatProviderStore.load()
        if !stored.isEmpty {
            attachLegacyFieldsIfNeeded(to: stored)
            return stored
        }
        // Seed from the legacy config once; empty model means the user never
        // configured the OpenAI backend, so nothing to seed.
        guard !model().isEmpty, !baseURL().absoluteString.isEmpty else { return [] }
        let seededProvider = ChatProvider(
            name: "Default",
            baseURL: baseURL().absoluteString,
            models: [
                ChatModel(
                    name: model(),
                    model: model(),
                    systemPrompt: systemPrompt().isEmpty ? nil : systemPrompt(),
                    reasoningEnabled: reasoningEnabled(),
                    reasoningEffort: reasoningEnabled() ? reasoningEffort() : nil
                )
            ]
        )
        chatProviderStore.save([seededProvider])
        setSelectedModelProfileID(seededProvider.models[0].id)
        try? setProviderAPIKey(seededProvider.id, apiKey())
        try? setProviderHeaders(id: seededProvider.id, customHeaders())
        markLegacyFieldsAttached()
        return [seededProvider]
    }

    /// Legacy globals were copied into providers once; the flag makes the
    /// copy idempotent so later edits to per-model fields are never
    /// overwritten by a re-read of the old defaults.
    private static func legacyFieldsAttached() -> Bool {
        UserDefaults.standard.bool(forKey: "companion.legacyFieldsAttachedToProviders")
    }

    private static func markLegacyFieldsAttached() {
        UserDefaults.standard.set(true, forKey: "companion.legacyFieldsAttachedToProviders")
    }

    /// One-time copy of the legacy global fields (system prompt, reasoning
    /// toggle and effort, headers) into migrated providers and their models.
    /// Runs once across launches: after it fires, per-model edits stick and
    /// the old defaults are never re-read.
    private static func attachLegacyFieldsIfNeeded(to providers: [ChatProvider]) {
        guard !legacyFieldsAttached() else { return }
        // Nothing to copy when the old backend was never configured.
        guard !model().isEmpty else {
            markLegacyFieldsAttached()
            return
        }
        let headers = customHeaders()
        let prompt = systemPrompt()
        let reasoningOn = reasoningEnabled()
        let effort = reasoningEffort()
        var updated = providers
        for index in updated.indices {
            if !headers.isEmpty {
                try? setProviderHeaders(id: updated[index].id, headers)
            }
            for modelIndex in updated[index].models.indices where updated[index].models[modelIndex].systemPrompt == nil
                && updated[index].models[modelIndex].reasoningEnabled == nil {
                if !prompt.isEmpty {
                    updated[index].models[modelIndex].systemPrompt = prompt
                }
                updated[index].models[modelIndex].reasoningEnabled = reasoningOn
                if reasoningOn, updated[index].models[modelIndex].reasoningEffort == nil,
                   !effort.isEmpty {
                    updated[index].models[modelIndex].reasoningEffort = effort
                }
            }
        }
        chatProviderStore.save(updated)
        markLegacyFieldsAttached()
    }

    /// The (provider, model) pair the chat panel uses; nil falls back to
    /// the legacy single-model config.
    static func selectedModel() -> (provider: ChatProvider, model: ChatModel)? {
        let providers = chatProviders()
        guard !providers.isEmpty else { return nil }
        let storedID = UserDefaults.standard.string(forKey: Constants.Defaults.companionSelectedModelProfile)
        if let storedID, let id = UUID(uuidString: storedID) {
            for provider in providers {
                if let model = provider.model(id: id) {
                    return (provider, model)
                }
            }
            // A migrated selection still holds the legacy profile id, which
            // became the provider id; resolve it to that provider's first
            // model so the user keeps their chosen endpoint.
            for provider in providers where provider.id == id {
                if let first = provider.models.first {
                    return (provider, first)
                }
            }
        }
        // Fall back to the first provider's first model.
        guard let provider = providers.first, let model = provider.models.first else { return nil }
        return (provider, model)
    }

    /// Backward-compatible accessor: the selected pair flattened into the
    /// legacy profile shape for code that only needs endpoint + model string.
    static func selectedModelProfile() -> ModelProfile? {
        guard let (provider, model) = selectedModel() else { return nil }
        return ModelProfile(
            id: model.id,
            name: model.name,
            baseURL: provider.baseURL,
            model: model.model,
            reasoningEffort: model.reasoningEffort,
            isLocalMLX: provider.isLocalMLX
        )
    }

    static func setSelectedModelProfileID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Constants.Defaults.companionSelectedModelProfile)
        SettingsSavedBus.announce()
    }

    /// Per-provider API key in the Keychain. Same prefix as the legacy
    /// per-profile keys, so migrated providers keep working keys.
    static func providerAPIKey(id: UUID) -> String {
        keychainString(ChatProviderStore.keychainKeyPrefix + id.uuidString)
    }

    static func setProviderAPIKey(_ id: UUID, _ key: String) throws {
        try KeychainHelper.save(key: ChatProviderStore.keychainKeyPrefix + id.uuidString, data: Data(key.utf8))
        SettingsSavedBus.announce()
    }

    /// Deletes a provider and its Keychain key. Selection falls back to the
    /// first remaining provider and model when the deleted one held it.
    static func deleteProvider(id: UUID) {
        var providers = chatProviders()
        providers.removeAll { $0.id == id }
        chatProviderStore.save(providers)
        try? KeychainHelper.delete(key: ChatProviderStore.keychainKeyPrefix + id.uuidString)
    }

    /// Deletes a single model from its provider, keeping the provider.
    static func deleteModel(id: UUID, in providerID: UUID) {
        var providers = chatProviders()
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[index].models.removeAll { $0.id == id }
        chatProviderStore.save(providers)
    }

    // MARK: - Per-provider headers (Keychain)

    /// Headers sent with every request to this provider. Values can be
    /// secrets, so the list lives in the Keychain as JSON, never inside the
    /// UserDefaults blob.
    static let providerHeadersKeychainKeyPrefix =
        "com.businessbar.companion.provider.headers."

    static func providerHeaders(id: UUID) -> [(name: String, value: String)] {
        guard let data = try? KeychainHelper.load(key: providerHeadersKeychainKeyPrefix + id.uuidString),
              let raw = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return [] }
        return raw.compactMap { pair in
            guard let name = pair["name"], let value = pair["value"] else { return nil }
            return (name, value)
        }
    }

    static func setProviderHeaders(id: UUID, _ headers: [(name: String, value: String)]) throws {
        let raw = headers.map { ["name": $0.name, "value": $0.value] }
        guard let data = try? JSONEncoder().encode(raw) else {
            throw CocoaError(.coderInvalidValue)
        }
        try KeychainHelper.save(key: providerHeadersKeychainKeyPrefix + id.uuidString, data: data)
        SettingsSavedBus.announce()
    }

    // MARK: - Local MLX provider

    /// Creates or updates the preset provider pointing at the managed MLX
    /// server. Provider id stays stable across updates, and its single model
    /// follows the active catalog model.
    static func upsertLocalMLXProvider() -> ChatProvider? {
        guard let modelID = MLXServerConfig.activeModelID(),
              let entry = MLXModelCatalog.entry(id: modelID) else { return nil }
        let model = ChatModel(
            name: entry.displayName,
            model: modelID,
            acceptsText: true,
            acceptsImages: entry.kind == .textAndImages
        )
        let provider = ChatProvider(
            name: "Local (MLX)",
            baseURL: MLXServerConfig.baseURLString(),
            models: [model],
            isLocalMLX: true
        )
        var providers = chatProviders()
        if let index = providers.firstIndex(where: { $0.isLocalMLX == true }) {
            var updated = provider
            updated.id = providers[index].id
            // Keep the existing model id when the catalog model has not
            // changed so selection survives updates.
            if let existing = providers[index].models.first, existing.model == modelID {
                var kept = model
                kept.id = existing.id
                updated.models = [kept]
            }
            providers[index] = updated
            chatProviderStore.save(providers)
            return updated
        }
        providers.append(provider)
        chatProviderStore.save(providers)
        return provider
    }

    /// Starts or restarts the MLX server when the selected chat model is
    /// the local preset. Callers await this before streaming; a nil return
    /// means no local server is involved and the request can go straight
    /// out.
    static func ensureLocalServerIfNeeded() async throws {
        try await ensureLocalServer(forModelID: nil)
    }

    /// Same warm-up for a specific model id: rewrite templates that pin a
    /// local MLX companion model need the server up before their stream,
    /// even when the chat panel's selected model is remote.
    static func ensureLocalServer(forModelID modelID: UUID?) async throws {
        guard backend() == .openai else { return }
        var pair: (provider: ChatProvider, model: ChatModel)?
        if let modelID {
            for provider in chatProviders() {
                if let model = provider.model(id: modelID) {
                    pair = (provider, model)
                    break
                }
            }
        }
        guard let (provider, model) = pair ?? selectedModel(),
              provider.isLocalMLX == true else { return }
        try await MLXServerManager.shared.ensureRunning(modelID: model.model)
    }

    // MARK: - Ad-hoc chat effort

    /// Effort the chat panel uses for its next request; empty string means
    /// "use the profile/default effort".
    static func adhocChatEffort() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionAdhocEffort) ?? ""
    }

    static func setAdhocChatEffort(_ effort: String) {
        UserDefaults.standard.set(effort, forKey: Constants.Defaults.companionAdhocEffort)
    }

    /// Whether the chat input starts in its tall layout. The toggle in the
    /// input bar flips it and the choice survives restarts.
    static func chatInputExpanded() -> Bool {
        UserDefaults.standard.bool(forKey: Constants.Defaults.companionInputExpanded)
    }

    static func setChatInputExpanded(_ expanded: Bool) {
        UserDefaults.standard.set(expanded, forKey: Constants.Defaults.companionInputExpanded)
        SettingsSavedBus.announce()
    }

    // MARK: - Reasoning

    static func reasoningEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Constants.Defaults.companionReasoning)
    }

    static func setReasoningEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Constants.Defaults.companionReasoning)
    }

    static func reasoningEffort() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionReasoningEffort)
            ?? Constants.DefaultValues.companionReasoningEffort
    }

    static func setReasoningEffort(_ effort: String) {
        UserDefaults.standard.set(effort, forKey: Constants.Defaults.companionReasoningEffort)
    }

    /// Effort values offered in the picker. The set is the union of what
    /// OpenAI models accept (low/medium/high/max) and gateway variants seen
    /// in the wild (none, xhigh).
    static let effortLevels = ["none", "low", "medium", "high", "xhigh", "max"]

    // MARK: - History retention

    /// Days after which a saved conversation is deleted. Zero keeps forever.
    static func historyMaxAgeDays() -> Int {
        UserDefaults.standard.integer(forKey: Constants.Defaults.companionHistoryMaxAgeDays)
    }

    static func setHistoryMaxAgeDays(_ days: Int) {
        UserDefaults.standard.set(days, forKey: Constants.Defaults.companionHistoryMaxAgeDays)
    }

    /// Maximum number of saved conversations; older ones get deleted.
    /// Zero keeps everything.
    static func historyMaxSessions() -> Int {
        UserDefaults.standard.integer(forKey: Constants.Defaults.companionHistoryMaxSessions)
    }

    static func setHistoryMaxSessions(_ count: Int) {
        UserDefaults.standard.set(count, forKey: Constants.Defaults.companionHistoryMaxSessions)
    }

    // MARK: - Custom request headers (Keychain)

    /// Header pairs sent with every chat request. Values can be secrets, so
    /// the whole list lives in the Keychain as JSON, not in UserDefaults.
    static func customHeaders() -> [(name: String, value: String)] {
        guard let data = try? KeychainHelper.load(key: customHeadersKeychainKey),
              let raw = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return [] }
        return raw.compactMap { pair in
            guard let name = pair["name"], let value = pair["value"] else { return nil }
            return (name, value)
        }
    }

    static func setCustomHeaders(_ headers: [(name: String, value: String)]) throws {
        let raw = headers.map { ["name": $0.name, "value": $0.value] }
        guard let data = try? JSONEncoder().encode(raw) else {
            throw CocoaError(.coderInvalidValue)
        }
        try KeychainHelper.save(key: customHeadersKeychainKey, data: data)
        SettingsSavedBus.announce()
    }

    // MARK: - ACP configuration

    static func acpCommand() -> String {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionACPCommand) ?? ""
    }

    static func setACPCommand(_ command: String) {
        UserDefaults.standard.set(command, forKey: Constants.Defaults.companionACPCommand)
    }

    static func acpArguments() -> [String] {
        UserDefaults.standard.stringArray(forKey: Constants.Defaults.companionACPArguments) ?? []
    }

    static func setACPArguments(_ arguments: [String]) {
        UserDefaults.standard.set(arguments, forKey: Constants.Defaults.companionACPArguments)
    }

    // MARK: - Client

    /// True when the OpenAI-compatible backend is usable: the selected
    /// provider's model and key resolve.
    static func isOpenAIConfigured() -> Bool {
        guard let (provider, model) = selectedModel() else { return false }
        let key = providerAPIKey(id: provider.id)
        return !model.model.isEmpty && (provider.isLocalMLX == true || !key.isEmpty)
    }

    /// True when the ACP backend is usable: a command is set.
    static func isACPConfigured() -> Bool {
        !acpCommand().isEmpty
    }

    /// True when the selected backend is usable.
    static func isConfigured() -> Bool {
        switch backend() {
        case .openai: return isOpenAIConfigured()
        case .acp: return isACPConfigured()
        }
    }

    /// Builds the client for the selected backend. Returns nil when not
    /// configured; callers surface a setup message.
    ///
    /// ACP returns the same long-lived instance per call so the subprocess
    /// and session survive across prompts; the panel controller owns its
    /// lifecycle (shutdown on close).
    static func makeClient() -> LLMClient? {
        switch backend() {
        case .openai:
            // Providers fully own the OpenAI endpoint now: the default
            // model's provider carries base URL, key, headers and per-model
            // reasoning, so the rewrite path and the chat panel resolve the
            // same way.
            return makeChatClient()
        case .acp:
            return acpConfiguredClient()
        }
    }

    /// ACP client when configured, else nil so callers surface setup.
    private static func acpConfiguredClient() -> LLMClient? {
        guard isACPConfigured() else { return nil }
        return acpClient()
    }

    /// Chat panel client: uses the selected provider+model when one exists,
    /// else the legacy single-model config. Fresh per call so model and
    /// effort switches take effect on the next message.
    ///
    /// Command tools (when enabled) merge their schemas here and raise
    /// the tool-round budget: background polling is unusable at 3 rounds.
    /// The command handler itself is per-panel state, so it flows through
    /// `stream(onToolCall:)`, not the stored handler.
    static func makeChatClient() -> LLMClient? {
        let commands = commandToolsEnabled() && backend() == .openai
        guard backend() == .openai else { return acpConfiguredClient() }
        // Providers own the endpoint now; no selected model means the
        // backend is not configured (the rewrite path shares this rule).
        guard let (provider, model) = selectedModel() else { return nil }
        let key = providerAPIKey(id: provider.id)
        // Local MLX providers serve without a key; everything else needs one.
        guard !model.model.isEmpty, provider.isLocalMLX == true || !key.isEmpty else { return nil }
        var normalized = provider.baseURL
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard let url = URL(string: normalized) else { return nil }
        return OpenAICompatClient(
            configuration: CompanionConfiguration(
                baseURL: url,
                model: model.model,
                apiKey: key,
                systemPrompt: model.systemPrompt ?? "",
                reasoning: model.reasoningEnabled == true,
                reasoningEffort: model.reasoningEnabled == true
                    ? (model.reasoningEffort ?? "medium")
                    : nil,
                extraHeaders: Dictionary(
                    uniqueKeysWithValues: providerHeaders(id: provider.id).map { ($0.name, $0.value) }
                )
            ),
            tools: chatToolSchemas(),
            toolHandler: searchToolHandler(),
            maxToolRounds: commands ? 20 : 3
        )
    }

    /// Client for one specific model, used by rewrite templates that pin a
    /// companion model. The model id comes from the template's `modelID`;
    /// nil or a stale id falls back to the selected chat model. The rewrite
    /// path never advertises tools, mirroring the chat client's schema merge
    /// rules minus the command handler.
    static func makeClient(forModelID modelID: UUID?) -> LLMClient? {
        guard backend() == .openai else { return makeClient() }
        let providers = chatProviders()
        var pair: (provider: ChatProvider, model: ChatModel)?
        if let modelID {
            for provider in providers {
                if let model = provider.model(id: modelID) {
                    pair = (provider, model)
                    break
                }
            }
        }
        guard let (provider, model) = pair ?? selectedModel() else { return nil }
        let key = providerAPIKey(id: provider.id)
        guard !model.model.isEmpty, provider.isLocalMLX == true || !key.isEmpty else { return nil }
        var normalized = provider.baseURL
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard let url = URL(string: normalized) else { return nil }
        return OpenAICompatClient(
            configuration: CompanionConfiguration(
                baseURL: url,
                model: model.model,
                apiKey: key,
                systemPrompt: model.systemPrompt ?? "",
                reasoning: model.reasoningEnabled == true,
                reasoningEffort: model.reasoningEnabled == true
                    ? (model.reasoningEffort ?? "medium")
                    : nil,
                extraHeaders: Dictionary(
                    uniqueKeysWithValues: providerHeaders(id: provider.id).map { ($0.name, $0.value) }
                )
            ),
            tools: [],
            toolHandler: nil,
            maxToolRounds: 3
        )
    }

    /// Schemas offered on the chat panel: search plus command tools when
    /// the user enabled them. The rewrite flow never gets command tools:
    /// it passes no per-call handler, so an advertised run_command would
    /// have nothing behind it.
    static func chatToolSchemas() -> [[String: Any]] {
        var schemas = searchTools()
        if commandToolsEnabled() && backend() == .openai {
            schemas.append(contentsOf: CommandToolCatalog.toolSchemas())
        }
        return schemas
    }

    // MARK: - Command tools

    /// User-facing switch for the command execution tools. Off by default;
    /// enabling is an explicit opt-in like the search providers.
    static func commandToolsEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "companion.commandToolsEnabled")
    }

    static func setCommandToolsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "companion.commandToolsEnabled")
        SettingsSavedBus.announce()
    }

    /// Default run_command activation for new chat sessions. The header
    /// picker in the chat can override it per session.
    static func commandPermissionMode() -> CommandPermissionMode {
        CommandPermissionMode(
            rawValue: UserDefaults.standard.string(forKey: "companion.commandPermissionMode") ?? ""
        ) ?? .ask
    }

    static func setCommandPermissionMode(_ mode: CommandPermissionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "companion.commandPermissionMode")
        SettingsSavedBus.announce()
    }

    /// Default working dir for new chat sessions. Falls back to home so
    /// the tools work before any pick, same rule as the chat header.
    static func commandDefaultWorkingDir() -> String {
        let raw = UserDefaults.standard.string(forKey: Constants.Defaults.companionCommandDefaultWorkingDir)
        guard let raw, !raw.isEmpty,
              FileManager.default.fileExists(atPath: raw) else {
            return NSHomeDirectory()
        }
        return raw
    }

    static func setCommandDefaultWorkingDir(_ path: String) {
        UserDefaults.standard.set(path, forKey: Constants.Defaults.companionCommandDefaultWorkingDir)
        SettingsSavedBus.announce()
    }

    /// Effort the chat panel's next request should use: the ad-hoc pick if
    /// set, else nil so the profile/global default applies.
    static func chatEffortOverride() -> String? {
        let adhoc = adhocChatEffort()
        return adhoc.isEmpty ? nil : adhoc
    }

    /// Shared ACP client so chat and rewrite reuse the same process and
    /// session. Cached per configuration so prefs edits swap clients; the
    /// old process is shut down when the key changes.
    private static let acpLock = NSLock()
    private static var cachedACPClient: ACPAgentClient?
    private static var cachedACPKey: String?

    static func acpClient() -> LLMClient {
        let configuration = ACPAgentConfiguration(
            command: acpCommand(),
            arguments: acpArguments(),
            systemPrompt: systemPrompt().isEmpty ? nil : systemPrompt()
        )
        let key = "\(configuration.command)\u{0}\(configuration.arguments)\u{0}\(configuration.systemPrompt ?? "")"

        acpLock.lock()
        if let cached = cachedACPClient, cachedACPKey == key {
            acpLock.unlock()
            return cached
        }
        let stale = cachedACPClient
        cachedACPClient = ACPAgentClient(configuration: configuration)
        cachedACPKey = key
        acpLock.unlock()

        if let stale {
            Task { await stale.shutdown() }
        }
        return cachedACPClient!
    }

    /// Shuts down the shared ACP subprocess. Called when the chat panel
    /// closes so no process outlives the UI that needed it.
    static func shutdownACP() async {
        let client = currentACPClient()
        await client?.shutdown()
    }

    /// Synchronous variant for app termination: async tasks may never run
    /// before the process exits, so this terminates the subprocess directly.
    static func shutdownACPSync() {
        currentACPClient()?.terminateNow()
    }

    /// Lock-protected read of the cached client; keeps NSLock usage out of
    /// async contexts (Swift 6 forbids it there).
    private nonisolated static func currentACPClient() -> ACPAgentClient? {
        acpLock.lock()
        defer { acpLock.unlock() }
        return cachedACPClient
    }

    // MARK: - Search tool plumbing

    /// Tool schemas offered to the model: web_search when a provider
    /// resolves, github_search when enabled with a token. Empty when both
    /// are unavailable.
    static func searchTools() -> [[String: Any]] {
        var schemas: [[String: Any]] = []
        if makeSearchProvider() != nil {
            schemas.append(SearchToolCatalog.webSearchToolSchema())
        }
        if makeGitHubSearchProvider() != nil {
            schemas.append(SearchToolCatalog.githubSearchToolSchema())
        }
        return schemas
    }

    /// Resolves the configured search provider, nil when disabled or a
    /// required key/endpoint is missing.
    static func makeSearchProvider() -> SearchProvider? {
        switch searchProviderKind() {
        case "scrape-ddg":
            return ScrapedSearchProvider(engine: .duckduckgo)
        case "scrape-bing":
            return ScrapedSearchProvider(engine: .bing)
        case "scrape-google-news":
            return ScrapedSearchProvider(engine: .googleNews)
        case "brave":
            let key = braveKey()
            guard !key.isEmpty else { return nil }
            return BraveSearchProvider(apiKey: key)
        case "tavily":
            let key = tavilyKey()
            guard !key.isEmpty else { return nil }
            return TavilySearchProvider(apiKey: key)
        case "custom":
            guard let endpoint = customSearchEndpoint() else { return nil }
            var headers = customSearchHeaders()
            // Legacy single header migrates into the list on first use.
            if headers.isEmpty {
                let name = customSearchHeaderName()
                let value = customSearchKey()
                if !name.isEmpty, !value.isEmpty {
                    headers = [(name, value)]
                }
            }
            return CustomSearchProvider(endpoint: endpoint, headers: headers)
        default:
            return nil
        }
    }

    /// GitHub code search provider, nil when the toggle is off or no
    /// token is stored.
    static func makeGitHubSearchProvider() -> GitHubSearchProvider? {
        guard githubSearchEnabled() else { return nil }
        let token = githubSearchKey()
        guard !token.isEmpty else { return nil }
        return GitHubSearchProvider(token: token)
    }

    /// Returns the onToolCall handler routing web_search and github_search
    /// to their providers, or nil when neither is available.
    static func searchToolHandler() -> ((String, String) async -> String)?
    {
        let webProvider = makeSearchProvider()
        let githubProvider = makeGitHubSearchProvider()
        guard webProvider != nil || githubProvider != nil else { return nil }
        return { name, argumentsJSON in
            let provider: SearchProvider?
            switch name {
            case "web_search":
                provider = webProvider
            case "github_search":
                provider = githubProvider
            default:
                return "Error: unknown tool \(name)"
            }
            guard let provider else {
                return "Error: \(name) is not configured"
            }
            guard let query = Self.query(fromArgumentsJSON: argumentsJSON) else {
                return "Error: missing 'query' argument"
            }
            do {
                let results = try await provider.search(query: query, maxResults: 5)
                return SearchToolCatalog.toolOutput(from: results)
            } catch {
                return "Search failed: \(error.localizedDescription)"
            }
        }
    }

    private static func query(fromArgumentsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["query"] as? String
    }
}