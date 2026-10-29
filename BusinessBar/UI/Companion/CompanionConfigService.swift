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

    /// Which LLM backend the companion uses. Kept for the migration read
    /// below; the live value derives from the selected provider's kind now:
    /// an ACP provider selected means ACP, anything else means OpenAI.
    enum Backend: String {
        case openai
        case acp
    }

    /// The selected provider decides: an ACP agent provider routes chat
    /// through the stdio client, every other kind speaks OpenAI-compatible.
    /// Falls back to the stored legacy key once when no provider matches it,
    /// so an existing ACP user keeps their backend until the seeded ACP
    /// provider takes over (see `chatProviders()`).
    static func backend() -> Backend {
        if selectedProvider()?.kind == .acpAgent {
            return .acp
        }
        if legacyBackendIsACP(), selectedProvider() == nil {
            return .acp
        }
        return .openai
    }

    /// Stored legacy backend key, read once per call. After the ACP provider
    /// migration seeds the entry, selection alone drives `backend()` and
    /// this key stops mattering.
    private static func legacyBackendIsACP() -> Bool {
        UserDefaults.standard.string(forKey: Constants.Defaults.companionBackend) == Backend.acp.rawValue
    }

    /// Kept for a hypothetical downgrade and for tests: writes the legacy
    /// key. New UI never calls it.
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
        var stored = chatProviderStore.load()
        if !stored.isEmpty {
            attachLegacyFieldsIfNeeded(to: &stored)
            return seedLegacyACPProviderIfNeeded(into: stored)
        }
        // No providers at all yet: a legacy ACP setup still deserves its
        // entry, so seed it before the OpenAI fallback below runs.
        let seededACP = seedLegacyACPProviderIfNeeded(into: [])
        if !seededACP.isEmpty {
            return seededACP
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

    /// One-time migration from the global ACP config (backend picker era)
    /// to a provider entry. Runs when the legacy backend key says ACP and no
    /// ACP provider exists yet; keeps the stored command and arguments and
    /// selects the new provider so the effective backend never changes.
    /// Returns the list including the seeded agent, unchanged when the
    /// migration does not apply.
    private static func seedLegacyACPProviderIfNeeded(into providers: [ChatProvider]) -> [ChatProvider] {
        guard legacyBackendIsACP(),
              !providers.contains(where: { $0.kind == .acpAgent }) else { return providers }
        let command = acpCommand()
        guard !command.isEmpty else { return providers }
        let agent = ChatProvider(
            name: ACPAgentConfiguration(command: command).agentName,
            baseURL: "",
            models: [],
            kind: .acpAgent,
            acpCommand: command,
            acpArguments: acpArguments()
        )
        let updated = providers + [agent]
        chatProviderStore.save(updated)
        setSelectedModelProfileID(agent.id)
        // Clear the legacy key so this seed never runs twice; selection owns
        // the backend from here on.
        UserDefaults.standard.removeObject(forKey: Constants.Defaults.companionBackend)
        return updated
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
    ///
    /// Mutates the array in place: the ACP seed below appends to the same
    /// array and saves it, so a lost mutation here would wipe the attach
    /// from the store while the flag marks it done.
    private static func attachLegacyFieldsIfNeeded(to providers: inout [ChatProvider]) {
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
        for index in providers.indices {
            if !headers.isEmpty {
                try? setProviderHeaders(id: providers[index].id, headers)
            }
            for modelIndex in providers[index].models.indices where providers[index].models[modelIndex].systemPrompt == nil
                && providers[index].models[modelIndex].reasoningEnabled == nil {
                if !prompt.isEmpty {
                    providers[index].models[modelIndex].systemPrompt = prompt
                }
                providers[index].models[modelIndex].reasoningEnabled = reasoningOn
                if reasoningOn, providers[index].models[modelIndex].reasoningEffort == nil,
                   !effort.isEmpty {
                    providers[index].models[modelIndex].reasoningEffort = effort
                }
            }
        }
        chatProviderStore.save(providers)
        markLegacyFieldsAttached()
    }

    /// The provider the stored selection points at: either a model's parent
    /// or an ACP agent entry. Nil when nothing resolves.
    static func selectedProvider() -> ChatProvider? {
        let providers = chatProviders()
        guard let storedID = UserDefaults.standard.string(forKey: Constants.Defaults.companionSelectedModelProfile),
              let id = UUID(uuidString: storedID) else {
            return nil
        }
        if let agent = providers.first(where: { $0.id == id && $0.kind == .acpAgent }) {
            return agent
        }
        for provider in providers where provider.model(id: id) != nil {
            return provider
        }
        return nil
    }

    /// The selected ACP agent, when the stored selection points at one.
    /// Chat sends here instead of `selectedModel()`; nil means an
    /// OpenAI-compatible model is selected (or nothing is).
    static func selectedACPProvider() -> ChatProvider? {
        guard let provider = selectedProvider(), provider.kind == .acpAgent else { return nil }
        return provider
    }

    /// The (provider, model) pair the chat panel uses; nil when an ACP
    /// agent is selected or nothing resolves. ACP agents have no models,
    /// so callers switch on `selectedACPProvider()` first.
    static func selectedModel() -> (provider: ChatProvider, model: ChatModel)? {
        if selectedACPProvider() != nil { return nil }
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
            for provider in providers
            where provider.id == id && provider.kind != .acpAgent {
                if let first = provider.models.first {
                    return (provider, first)
                }
            }
        }
        // Fall back to the first provider's first model.
        guard let provider = providers.first(where: { $0.kind != .acpAgent }),
              let model = provider.models.first else { return nil }
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
            isLocalMLX: provider.kind == .localMLX
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
        // Discover reasoning from the snapshot when the weights are on
        // disk; a downloaded model carries its own chat template, so no
        // guesswork from the name. The result is cached on the catalog so
        // later upserts and pickers read it without touching the disk again.
        if MLXModelCatalog.isDownloaded(modelID: modelID),
           entry.reasoning == nil {
            let capability = MLXReasoningInspector.capabilityFromSnapshot(modelID: modelID)
            MLXModelCatalog.setReasoningCapability(id: modelID, capability)
        }
        let capability = MLXModelCatalog.reasoningCapability(id: modelID)
        let model = ChatModel(
            name: entry.displayName,
            model: modelID,
            reasoningEnabled: capability.supported,
            reasoningEffort: capability.supported ? "medium" : nil,
            acceptsText: true,
            acceptsImages: entry.kind == .textAndImages,
            effortOptions: capability.effortOptions.isEmpty ? nil : capability.effortOptions
        )
        let provider = ChatProvider(
            name: "Local (MLX)",
            baseURL: MLXServerConfig.baseURLString(),
            models: [model],
            kind: .localMLX,
            isLocalMLX: true
        )
        var providers = chatProviders()
        if let index = providers.firstIndex(where: { $0.kind == .localMLX }) {
            var updated = provider
            updated.id = providers[index].id
            // Keep the existing model id when the catalog model has not
            // changed so selection survives updates. Reasoning picks stay
            // user-owned: detection only fills them in the first time.
            if let existing = providers[index].models.first, existing.model == modelID {
                var kept = model
                kept.id = existing.id
                kept.reasoningEnabled = existing.reasoningEnabled ?? kept.reasoningEnabled
                kept.reasoningEffort = existing.reasoningEffort ?? kept.reasoningEffort
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
        // Only the local MLX preset ever needs the server up; ACP agents
        // manage their own process and remote providers need nothing.
        if let modelID {
            if let provider = chatProviders().first(where: { $0.model(id: modelID) != nil }),
               provider.kind != .localMLX {
                return
            }
        } else if let selected = selectedProvider(), selected.kind != .localMLX {
            return
        }
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
              provider.kind == .localMLX else { return }
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
    static let effortLevels = EffortVocabulary.defaultLevels

    /// Effort vocabulary for one model row. Precedence: the model's own
    /// pinned list, then the local MLX discovery, then known model-name
    /// patterns, then the global list. A nil model falls back to the
    /// global list so template editors without a pinned model keep the
    /// full vocabulary.
    static func effortOptions(forModel model: ChatModel?, provider: ChatProvider? = nil) -> [String] {
        let mlxCapability: MLXReasoningCapability?
        if provider?.kind == .localMLX, let modelID = model?.model, !modelID.isEmpty {
            mlxCapability = MLXModelCatalog.reasoningCapability(id: modelID)
        } else {
            mlxCapability = nil
        }
        return EffortVocabulary.resolve(
            pinnedEffortOptions: model?.effortOptions,
            mlxModelID: provider?.kind == .localMLX ? model?.model : nil,
            mlxCapability: mlxCapability,
            modelID: model?.model
        )
    }

    /// Same lookup by model row id, resolving the owning provider so local
    /// MLX discovery applies. Falls back to the global list when the id
    /// no longer resolves.
    static func effortOptions(forModelID id: UUID) -> [String] {
        for provider in chatProviders() {
            if let model = provider.model(id: id) {
                return effortOptions(forModel: model, provider: provider)
            }
        }
        return effortLevels
    }

    /// Known reasoning vocabularies by model id. Model lists from
    /// OpenAI-compatible endpoints carry no capability metadata, so
    /// families with published effort sets are recognized here and
    /// everything else keeps the global list.
    static func knownModelEffortOptions(_ model: String) -> [String] {
        EffortVocabulary.knownModelEffortOptions(model)
    }

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

    // MARK: - Remote model list

    /// One entry from a provider's GET /models response.
    struct RemoteModelInfo: Identifiable, Equatable {
        public let id: String
        /// Effort values read off the entry when the endpoint publishes them
        /// (OpenRouter's supported_parameters carries reasoning_effort).
        public let effortOptions: [String]?
        public let supportsReasoning: Bool

        init(id: String, effortOptions: [String]? = nil, supportsReasoning: Bool = false) {
            self.id = id
            self.effortOptions = effortOptions
            self.supportsReasoning = supportsReasoning
        }
    }

    /// Fetches the model list from an OpenAI-compatible endpoint, GET
    /// {baseURL}/models with the given key and headers. The response
    /// carries no capability metadata on most servers, so reasoning hints
    /// ride along only when the endpoint publishes them.
    static func fetchRemoteModels(
        baseURL: String,
        apiKey: String,
        headers: [(name: String, value: String)] = [],
        session: URLSession = .shared
    ) async throws -> [RemoteModelInfo] {
        var normalized = baseURL
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard let url = URL(string: normalized + "/models") else {
            throw CocoaError(.fileNoSuchFile)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["data"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let params = entry["supported_parameters"] as? [String] ?? []
            let supportsReasoning = params.contains("reasoning")
                || params.contains("reasoning_effort")
                || (entry["reasoning"] as? Bool == true)
            let options = params.contains("reasoning_effort")
                ? effortLevels.filter { $0 != "none" } : nil
            return RemoteModelInfo(
                id: id,
                effortOptions: options,
                supportsReasoning: supportsReasoning
            )
        }
    }

    /// Same fetch for an already-saved provider, reading its stored key
    /// and headers.
    static func fetchRemoteModels(
        provider: ChatProvider,
        session: URLSession = .shared
    ) async throws -> [RemoteModelInfo] {
        try await fetchRemoteModels(
            baseURL: provider.baseURL,
            apiKey: providerAPIKey(id: provider.id),
            headers: providerHeaders(id: provider.id).map { ($0.name, $0.value) },
            session: session
        )
    }

    // MARK: - Client

    /// True when the OpenAI-compatible backend is usable: the selected
    /// provider's model and key resolve.
    static func isOpenAIConfigured() -> Bool {
        guard let (provider, model) = selectedModel() else { return false }
        let key = providerAPIKey(id: provider.id)
        return !model.model.isEmpty && (provider.kind == .localMLX || !key.isEmpty)
    }

    /// True when the selected ACP agent is usable: its command is set.
    static func isACPConfigured() -> Bool {
        guard let agent = selectedACPProvider() else { return false }
        return !agent.acpCommand.isEmpty
    }

    /// True when the selected provider is usable, whatever its kind.
    static func isConfigured() -> Bool {
        if let agent = selectedACPProvider() {
            return !agent.acpCommand.isEmpty
        }
        return isOpenAIConfigured()
    }

    /// Builds the client for the selected provider. Returns nil when not
    /// configured; callers surface a setup message.
    ///
    /// ACP returns the same long-lived instance per configuration so the
    /// subprocess and session survive across prompts; the panel controller
    /// owns its lifecycle (shutdown on close).
    static func makeClient() -> LLMClient? {
        if let agent = selectedACPProvider() {
            return acpClient(for: agent)
        }
        return makeChatClient()
    }

    /// Chat panel client: the selected provider+model, or the selected ACP
    /// agent. Fresh per call so model, effort and agent switches take effect
    /// on the next message.
    ///
    /// Command tools (when enabled) merge their schemas here and raise
    /// the tool-round budget: background polling is unusable at 3 rounds.
    /// The command handler itself is per-panel state, so it flows through
    /// `stream(onToolCall:)`, not the stored handler.
    static func makeChatClient() -> LLMClient? {
        if let agent = selectedACPProvider() {
            guard !agent.acpCommand.isEmpty else { return nil }
            return acpClient(for: agent)
        }
        let commands = commandToolsEnabled()
        // Providers own the endpoint now; no selected model means the
        // backend is not configured (the rewrite path shares this rule).
        guard let (provider, model) = selectedModel() else { return nil }
        let key = providerAPIKey(id: provider.id)
        // Local MLX providers serve without a key; everything else needs one.
        guard !model.model.isEmpty, provider.kind == .localMLX || !key.isEmpty else { return nil }
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
                ),
                isLocalMLX: provider.kind == .localMLX,
                mlxReasoning: provider.kind == .localMLX
                    ? MLXModelCatalog.reasoningCapability(id: model.model)
                    : nil
            ),
            tools: chatToolSchemas(),
            toolHandler: searchToolHandler(),
            maxToolRounds: commands ? 20 : 3
        )
    }

    /// Client for one specific model, used by rewrite templates that pin a
    /// companion model. The model id comes from the template's `modelID`;
    /// nil or a stale id falls back to the selected chat model. Templates
    /// pin models, never agents, so an ACP selection with no pinned id runs
    /// through `makeClient()` and lands on the agent. The rewrite path never
    /// advertises tools, mirroring the chat client's schema merge rules
    /// minus the command handler.
    static func makeClient(forModelID modelID: UUID?) -> LLMClient? {
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
        guard let (provider, model) = pair ?? selectedModel() else {
            return selectedACPProvider().map { acpClient(for: $0) }
        }
        let key = providerAPIKey(id: provider.id)
        guard !model.model.isEmpty, provider.kind == .localMLX || !key.isEmpty else { return nil }
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
                ),
                isLocalMLX: provider.kind == .localMLX,
                mlxReasoning: provider.kind == .localMLX
                    ? MLXModelCatalog.reasoningCapability(id: model.model)
                    : nil
            ),
            tools: [],
            toolHandler: nil,
            maxToolRounds: 3
        )
    }

    /// Schemas offered on the chat panel: search plus command tools when
    /// the user enabled them. ACP agents manage their own tools, so command
    /// schemas never join an ACP client. The rewrite flow never gets command
    /// tools: it passes no per-call handler, so an advertised run_command
    /// would have nothing behind it.
    static func chatToolSchemas() -> [[String: Any]] {
        var schemas = searchTools()
        // Command schemas need the OpenAI path's per-call handler; agents
        // negotiate their own tools.
        if commandToolsEnabled(), selectedACPProvider() == nil {
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

    // MARK: Command permission settings

    /// Per-category dials plus persistent prefix rules, assembled fresh
    /// per call so changes in Preferences reach the next command.
    static func commandPermissionSettings() -> CommandPermissionSettings {
        CommandPermissionSettings(
            categoryModes: commandCategoryModes(),
            allowedPrefixes: commandAllowedPrefixes(),
            deniedPrefixes: commandDeniedPrefixes()
        )
    }

    /// Explicit mode for one category; nil when the category follows the
    /// master mode.
    static func commandCategoryMode(_ category: CommandCategory) -> CommandPermissionMode? {
        guard let raw = UserDefaults.standard.string(
            forKey: "companion.commandPermission.category.\(category.rawValue)"
        ) else { return nil }
        return CommandPermissionMode(rawValue: raw)
    }

    static func setCommandCategoryMode(_ mode: CommandPermissionMode?, for category: CommandCategory) {
        let key = "companion.commandPermission.category.\(category.rawValue)"
        if let mode {
            UserDefaults.standard.set(mode.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        SettingsSavedBus.announce()
    }

    private static func commandCategoryModes() -> [CommandCategory: CommandPermissionMode] {
        var modes: [CommandCategory: CommandPermissionMode] = [:]
        for category in CommandCategory.allCases {
            if let mode = commandCategoryMode(category) {
                modes[category] = mode
            }
        }
        return modes
    }

    /// Persistent allow rules: exact commands or `prefix *` wildcards,
    /// added by "Always allow" on the approval card.
    static func commandAllowedPrefixes() -> [String] {
        UserDefaults.standard.stringArray(forKey: "companion.commandAllowedPrefixes") ?? []
    }

    static func setCommandAllowedPrefixes(_ prefixes: [String]) {
        UserDefaults.standard.set(prefixes, forKey: "companion.commandAllowedPrefixes")
        SettingsSavedBus.announce()
    }

    /// Persistent deny rules. Deny wins over allow rules and Allow mode.
    static func commandDeniedPrefixes() -> [String] {
        UserDefaults.standard.stringArray(forKey: "companion.commandDeniedPrefixes") ?? []
    }

    static func setCommandDeniedPrefixes(_ prefixes: [String]) {
        UserDefaults.standard.set(prefixes, forKey: "companion.commandDeniedPrefixes")
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
    /// session. Cached per configuration so provider edits swap clients; the
    /// old process is shut down when the key changes.
    private static let acpLock = NSLock()
    private static var cachedACPClient: ACPAgentClient?
    private static var cachedACPKey: String?

    /// ACP client for one agent provider. The cached key covers command,
    /// arguments and system prompt, so editing any of them restarts the
    /// subprocess on the next request while an unchanged config keeps its
    /// session alive across prompts.
    static func acpClient(for provider: ChatProvider) -> LLMClient {
        let configuration = ACPAgentConfiguration(
            command: provider.acpCommand,
            arguments: provider.acpArguments,
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