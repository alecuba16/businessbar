import BusinessBarCore
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
    static let braveKeychainKey = "com.businessbar.companion.braveKey"
    static let tavilyKeychainKey = "com.businessbar.companion.tavilyKey"
    static let customSearchKeychainKey = "com.businessbar.companion.customSearchKey"
    static let customHeadersKeychainKey = "com.businessbar.companion.customHeaders"

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
    }

    static func customSearchEndpoint() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: Constants.Defaults.companionCustomSearchEndpoint),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static func setCustomSearchEndpoint(_ url: URL?) {
        UserDefaults.standard.set(url?.absoluteString ?? "", forKey: Constants.Defaults.companionCustomSearchEndpoint)
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

    private static func keychainString(_ key: String) -> String {
        guard let data = try? KeychainHelper.load(key: key) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Model profiles

    /// Shared store for named model profiles (base URL + model + effort).
    static let modelProfileStore = ModelProfileStore()

    /// Loads profiles, seeding one from the legacy single-model config the
    /// first time so existing users keep their working setup.
    static func modelProfiles() -> [ModelProfile] {
        let stored = modelProfileStore.load()
        if !stored.isEmpty { return stored }
        // Seed from the legacy config once; empty model means the user never
        // configured the OpenAI backend, so nothing to seed.
        guard !model().isEmpty else { return [] }
        let seeded = ModelProfile(
            name: model(),
            baseURL: baseURL().absoluteString,
            model: model(),
            reasoningEffort: reasoningEnabled() ? reasoningEffort() : nil
        )
        modelProfileStore.save([seeded])
        setSelectedModelProfileID(seeded.id)
        try? setProfileAPIKey(seeded.id, apiKey())
        return [seeded]
    }

    /// The profile the chat panel uses; nil falls back to the legacy config.
    static func selectedModelProfile() -> ModelProfile? {
        let profiles = modelProfiles()
        guard !profiles.isEmpty else { return nil }
        let storedID = UserDefaults.standard.string(forKey: Constants.Defaults.companionSelectedModelProfile)
        if let storedID, let id = UUID(uuidString: storedID),
           let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    static func setSelectedModelProfileID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Constants.Defaults.companionSelectedModelProfile)
    }

    /// Per-profile API key in the Keychain.
    static func profileAPIKey(id: UUID) -> String {
        keychainString(ModelProfileStore.keychainKeyPrefix + id.uuidString)
    }

    static func setProfileAPIKey(_ id: UUID, _ key: String) throws {
        try KeychainHelper.save(key: ModelProfileStore.keychainKeyPrefix + id.uuidString, data: Data(key.utf8))
        SettingsSavedBus.announce()
    }

    /// Deletes a profile and its Keychain key. When the deleted profile
    /// was selected, selection falls back to the first remaining profile.
    static func deleteModelProfile(id: UUID) {
        var profiles = modelProfiles()
        profiles.removeAll { $0.id == id }
        modelProfileStore.save(profiles)
        if let first = profiles.first {
            setSelectedModelProfileID(first.id)
        }
        try? KeychainHelper.delete(key: ModelProfileStore.keychainKeyPrefix + id.uuidString)
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
    /// OpenAI models accept (low/medium/high) and gateway variants seen in
    /// the wild (none, xhigh).
    static let effortLevels = ["none", "low", "medium", "high", "xhigh"]

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

    /// True when the OpenAI-compatible backend is usable.
    static func isOpenAIConfigured() -> Bool {
        !model().isEmpty && !apiKey().isEmpty
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
            guard isOpenAIConfigured() else { return nil }
            return OpenAICompatClient(
                configuration: CompanionConfiguration(
                    baseURL: baseURL(),
                    model: model(),
                    apiKey: apiKey(),
                    systemPrompt: systemPrompt(),
                    reasoning: reasoningEnabled(),
                    reasoningEffort: reasoningEnabled() ? reasoningEffort() : nil,
                    extraHeaders: Dictionary(uniqueKeysWithValues: customHeaders().map { ($0.name, $0.value) })
                ),
                tools: searchTools(),
                toolHandler: searchToolHandler()
            )
        case .acp:
            guard isACPConfigured() else { return nil }
            return acpClient()
        }
    }

    /// Chat panel client: uses the selected model profile when one exists,
    /// else the legacy single-model config. Fresh per call so profile and
    /// effort switches take effect on the next message.
    static func makeChatClient() -> LLMClient? {
        guard backend() == .openai else { return makeClient() }
        guard let profile = selectedModelProfile() else { return makeClient() }
        let key = profileAPIKey(id: profile.id)
        guard !profile.model.isEmpty, !key.isEmpty else { return nil }
        var normalized = profile.baseURL
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard let url = URL(string: normalized) else { return nil }
        return OpenAICompatClient(
            configuration: CompanionConfiguration(
                baseURL: url,
                model: profile.model,
                apiKey: key,
                systemPrompt: systemPrompt(),
                reasoning: reasoningEnabled(),
                reasoningEffort: reasoningEnabled()
                    ? (profile.reasoningEffort ?? reasoningEffort())
                    : nil,
                extraHeaders: Dictionary(uniqueKeysWithValues: customHeaders().map { ($0.name, $0.value) })
            ),
            tools: searchTools(),
            toolHandler: searchToolHandler()
        )
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

    /// Tool schemas offered to the model; empty when search is disabled.
    static func searchTools() -> [[String: Any]] {
        guard makeSearchProvider() != nil else { return [] }
        return [SearchToolCatalog.webSearchToolSchema()]
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
            return CustomSearchProvider(
                endpoint: endpoint,
                headerName: customSearchHeaderName().isEmpty ? nil : customSearchHeaderName(),
                headerValue: customSearchKey().isEmpty ? nil : customSearchKey()
            )
        default:
            return nil
        }
    }

    /// Returns the onToolCall handler wiring web_search to the provider,
    /// or nil when search is disabled.
    static func searchToolHandler() -> ((String, String) async -> String)?
    {
        guard let provider = makeSearchProvider() else { return nil }
        return { name, argumentsJSON in
            guard name == "web_search" else {
                return "Error: unknown tool \(name)"
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