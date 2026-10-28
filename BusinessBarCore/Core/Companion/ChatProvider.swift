import Foundation

// MARK: - ChatModel

/// One model inside a provider: the model string sent to the endpoint plus
/// its default reasoning effort. The endpoint, key and headers live on the
/// provider, so a model stays a thin row.
public struct ChatModel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Model string sent in the request, for example "gpt-4o-mini".
    public var model: String
    /// System prompt for this model; empty falls back to none.
    public var systemPrompt: String?
    /// Reasoning toggle for this model. Nil on legacy rows means the
    /// global reasoning setting applies at migration time.
    public var reasoningEnabled: Bool?
    /// Reasoning effort for this model; nil falls back to the global default.
    public var reasoningEffort: String?

    public init(
        id: UUID = UUID(),
        name: String,
        model: String,
        systemPrompt: String? = nil,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.systemPrompt = systemPrompt
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, model, systemPrompt, reasoningEnabled, reasoningEffort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        reasoningEnabled = try container.decodeIfPresent(Bool.self, forKey: .reasoningEnabled)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }
}

// MARK: - ChatProvider

/// A named OpenAI-compatible endpoint (base URL, per-provider API key in the
/// Keychain, optional extra headers) hosting one or more models. Providers
/// and models evolve independently: swapping an endpoint keeps its models,
/// adding a model needs no new key.
public struct ChatProvider: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var models: [ChatModel]
    /// Header pairs sent with every request to this provider. Values can be
    /// secrets, so they are stored in the Keychain as JSON next to the key,
    /// never inside this blob.
    public var isLocalMLX: Bool?
    /// Legacy flag kept so a stored provider decodes after downgrade; new
    /// writes leave it out.
    public var headers: [HeaderPair]?

    public struct HeaderPair: Codable, Equatable, Hashable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        models: [ChatModel],
        isLocalMLX: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.isLocalMLX = isLocalMLX
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, models, isLocalMLX, headers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        models = try container.decodeIfPresent([ChatModel].self, forKey: .models) ?? []
        isLocalMLX = try container.decodeIfPresent(Bool.self, forKey: .isLocalMLX)
        headers = try container.decodeIfPresent([HeaderPair].self, forKey: .headers)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(models, forKey: .models)
        try container.encodeIfPresent(isLocalMLX, forKey: .isLocalMLX)
    }

    /// The model with the given id, if this provider hosts it.
    public func model(id: UUID) -> ChatModel? {
        models.first { $0.id == id }
    }
}

// MARK: - ChatProviderStore

/// Persists providers in UserDefaults as JSON. Provider ids are stable, so
/// the Keychain holds one key per provider under
/// `ChatProviderStore.keychainKeyPrefix + provider.id`.
public final class ChatProviderStore: @unchecked Sendable {
    /// Posted after `save` so UI pickers can re-sync.
    public static let didChangeNotification =
        Notification.Name("com.businessbar.companion.chatProviderStoreDidChange")

    public static let keychainKeyPrefix = "com.businessbar.companion.profile.apiKey."

    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "companion.chatProviders",
        legacyKey: String = "companion.modelProfiles"
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyKey = legacyKey
    }

    /// Loads providers, migrating a stored legacy `[ModelProfile]` blob once.
    /// The migration reuses each profile id as the provider id, so Keychain
    /// keys keep working without a re-entry.
    public func load() -> [ChatProvider] {
        lock.lock(); defer { lock.unlock() }
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ChatProvider].self, from: data) {
            return decoded
        }
        // First run on the new schema: convert the old flat profiles.
        if let legacyData = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode([ModelProfile].self, from: legacyData),
           !legacy.isEmpty {
            let migrated = legacy.map(ChatProvider.init(profile:))
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: key)
                // Keep the old blob in place: never destroy user data the
                // moment the new format lands. Rollback stays possible.
            }
            return migrated
        }
        return []
    }

    /// Replaces the stored set.
    public func save(_ providers: [ChatProvider]) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// True once a new-format blob exists.
    public var migrated: Bool {
        defaults.data(forKey: key) != nil
    }
}

// MARK: - Legacy migration

extension ChatProvider {
    /// Maps a legacy flat profile onto the new schema. Provider id keeps the
    /// profile id so the Keychain key still resolves.
    public init(profile: ModelProfile) {
        self.init(
            id: profile.id,
            name: profile.name,
            baseURL: profile.baseURL,
            models: [
                ChatModel(
                    name: profile.name,
                    model: profile.model,
                    reasoningEffort: profile.reasoningEffort
                )
            ],
            isLocalMLX: profile.isLocalMLX
        )
    }
}
