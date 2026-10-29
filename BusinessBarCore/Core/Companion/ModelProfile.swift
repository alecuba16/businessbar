import Foundation

// MARK: - ModelProfile

/// A named OpenAI-compatible endpoint preset: base URL, model id, default
/// reasoning effort. The API key lives in the Keychain per profile id, never
/// in this JSON blob.
public struct ModelProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var model: String
    /// Reasoning effort sent for this profile when reasoning is enabled.
    /// Nil falls back to the global default.
    public var reasoningEffort: String?
    /// True when the profile points at the app-managed MLX server. Such
    /// profiles need no API key and the server is started on demand.
    public var isLocalMLX: Bool?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        model: String,
        reasoningEffort: String? = nil,
        isLocalMLX: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.isLocalMLX = isLocalMLX
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, reasoningEffort, isLocalMLX
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        isLocalMLX = try container.decodeIfPresent(Bool.self, forKey: .isLocalMLX)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(isLocalMLX, forKey: .isLocalMLX)
    }
}

// MARK: - ModelProfileStore

/// Persists model profiles in UserDefaults as JSON. API keys are not part
/// of the blob; the app layer stores them in the Keychain under
/// `ModelProfileStore.keychainKeyPrefix + profile.id`.
public final class ModelProfileStore: @unchecked Sendable {
    /// Posted after `save` so UI pickers can re-sync.
    public static let didChangeNotification = Notification.Name("com.businessbar.companion.modelProfileStoreDidChange")

    public static let keychainKeyPrefix = "com.businessbar.companion.profile.apiKey."

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "companion.modelProfiles") {
        self.defaults = defaults
        self.key = key
    }

    /// Loads profiles. Empty when nothing is stored yet; the app seeds the
    /// first profile from the legacy single-model config on first use.
    public func load() -> [ModelProfile] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ModelProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Replaces the stored set.
    public func save(_ profiles: [ModelProfile]) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
