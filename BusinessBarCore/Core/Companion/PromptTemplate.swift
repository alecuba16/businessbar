import Foundation

// MARK: - PromptTemplate

/// A user-defined rewrite template. `prompt` may contain `[placeholder]`,
/// which is substituted with the selected text at trigger time.
public struct PromptTemplate: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var prompt: String
    /// When true, a rewrite that comes back wrapped in <output> tags
    /// replaces the selection directly instead of showing the overlay.
    public var autoReplace: Bool

    public init(id: UUID = UUID(), name: String, prompt: String, autoReplace: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.autoReplace = autoReplace
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, autoReplace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        // Templates stored before the flag existed decode as false.
        autoReplace = try container.decodeIfPresent(Bool.self, forKey: .autoReplace) ?? false
    }

    /// The token replaced by the selected text.
    public static let placeholder = "[placeholder]"

    /// Renders the prompt with `selection` substituted for `[placeholder]`.
    /// A template without the token gets the selection appended, so the
    /// rewrite always sees what the user selected.
    public func render(with selection: String) -> String {
        if prompt.contains(Self.placeholder) {
            return prompt.replacingOccurrences(of: Self.placeholder, with: selection)
        }
        return prompt + "\n\n" + selection
    }

    /// Default templates shipped on first launch. Placeholders demonstrate
    /// the token. Each prompt pins the output format to <output> tags with a
    /// worked example, so the overlay receives the raw text and nothing
    /// else.
    public static let defaults: [PromptTemplate] = [
        PromptTemplate(
            name: "Improve writing",
            prompt: "Improve the writing of the following text. Keep its language, meaning and approximate length.\n\nReply with the improved text inside <output></output> tags and nothing else. No preamble, no explanation. For example, if asked to improve ' Teh cat sat. ', reply exactly:\n<output>The cat sat.</output>\n\nText to improve:\n[placeholder]"
        ),
        PromptTemplate(
            name: "Fix grammar and spelling",
            prompt: "Correct grammar and spelling mistakes in the following text. Keep its language and meaning.\n\nReply with the corrected text inside <output></output> tags and nothing else. No preamble, no explanation. For example, if asked to correct ' She dont know. ', reply exactly:\n<output>She doesn't know.</output>\n\nText to correct:\n[placeholder]"
        ),
        PromptTemplate(
            name: "Make concise",
            prompt: "Rewrite the following text to be as concise as possible without losing information. Keep its language.\n\nReply with the rewritten text inside <output></output> tags and nothing else. No preamble, no explanation. For example, if asked to make concise ' Due to the fact that it was raining, we decided to stay home. ', reply exactly:\n<output>Because it was raining, we stayed home.</output>\n\nText to condense:\n[placeholder]"
        ),
        PromptTemplate(
            name: "Translate to English",
            prompt: "Translate the following text to English.\n\nReply with the translation inside <output></output> tags and nothing else. No preamble, no explanation. For example, if asked to translate ' El gato se sentó. ', reply exactly:\n<output>The cat sat down.</output>\n\nText to translate:\n[placeholder]"
        )
    ]
}

// MARK: - TemplateStore

/// Persists prompt templates in UserDefaults as JSON. The app layer owns
/// the instance; core stays UI-free.
public final class TemplateStore: @unchecked Sendable {
    /// Posted after `save` so shortcut registration can re-sync.
    public static let didChangeNotification = Notification.Name("com.businessbar.companion.templateStoreDidChange")

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "companion.promptTemplates") {
        self.defaults = defaults
        self.key = key
    }

    /// Loads templates. Falls back to `PromptTemplate.defaults` (and persists
    /// them) when nothing is stored yet.
    public func load() -> [PromptTemplate] {
        lock.lock(); defer { lock.unlock() }
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PromptTemplate].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        let initial = PromptTemplate.defaults
        saveLocked(initial)
        return initial
    }

    /// Replaces the stored set.
    public func save(_ templates: [PromptTemplate]) {
        lock.lock(); defer { lock.unlock() }
        saveLocked(templates)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func saveLocked(_ templates: [PromptTemplate]) {
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: key)
        }
    }
}
