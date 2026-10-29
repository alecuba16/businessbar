import Foundation

// MARK: - PromptTemplate

/// What happens to the model reply once it arrives.
public enum TemplateAction: String, Codable, Sendable {
    /// Show the rewrite overlay; the user decides where it goes.
    case overlay
    /// Replace the selection directly when the reply carries <output> tags
    /// and the app supports in-place replacement. Otherwise overlay.
    case replace
    /// Insert the reply right after the selection, keeping both. Falls back
    /// to the overlay when in-place insertion is not possible.
    case append
    /// Like `append`, but the reply starts on a new line below the
    /// selection instead of gluing onto its last line.
    case appendLineBreak

    public var label: String {
        switch self {
        case .overlay: return "Show overlay"
        case .replace: return "Replace selection"
        case .append: return "Insert after selection"
        case .appendLineBreak: return "Insert after selection (new line)"
        }
    }
}

/// A user-defined rewrite template. `prompt` may contain `[placeholder]`,
/// which is substituted with the selected text at trigger time.
public struct PromptTemplate: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var prompt: String
    /// What the rewrite does with the reply. Replaces the legacy
    /// `autoReplace` flag, which maps to `.replace`.
    public var action: TemplateAction
    /// Kept only so JSON stored by older versions decodes; always written
    /// from `action` on save.
    public var autoReplace: Bool
    /// Optional reasoning effort sent as `reasoning_effort` for this
    /// template's request. Nil means the global default applies.
    public var reasoningEffort: String?
    /// Companion model for this template: a ChatModel id from the providers
    /// list. Nil means the default chat model applies.
    public var modelID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        action: TemplateAction = .overlay,
        reasoningEffort: String? = nil,
        modelID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.action = action
        self.autoReplace = action == .replace
        self.reasoningEffort = reasoningEffort
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, action, autoReplace, reasoningEffort, modelID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        // Templates stored before the enum existed carry the bool flag.
        let storedAction = try container.decodeIfPresent(TemplateAction.self, forKey: .action)
        let storedFlag = try container.decodeIfPresent(Bool.self, forKey: .autoReplace) ?? false
        action = storedAction ?? (storedFlag ? .replace : .overlay)
        autoReplace = action == .replace
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        modelID = try container.decodeIfPresent(UUID.self, forKey: .modelID)
    }

    /// Encoded without nil so old readers skip the field cleanly.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(action, forKey: .action)
        try container.encode(autoReplace, forKey: .autoReplace)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(modelID, forKey: .modelID)
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
        ),
        PromptTemplate(
            name: "Format for Slack",
            prompt: "Rewrite the following text as a Slack message using Slack mrkdwn: *bold*, _italic_, ~strike~, `code`, and > for quotes. Keep it short and skimmable.\n\nReply with the message inside <output></output> tags and nothing else. No preamble, no explanation.\n\nText to format:\n[placeholder]",
            action: .append
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
    /// them) when nothing is stored yet, and appends any default missing from
    /// a stored list so new built-in templates reach existing users without
    /// touching their edits.
    public func load() -> [PromptTemplate] {
        lock.lock(); defer { lock.unlock() }
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PromptTemplate].self, from: data),
           !decoded.isEmpty {
            let storedNames = Set(decoded.map(\.name))
            let missing = PromptTemplate.defaults.filter { !storedNames.contains($0.name) }
            if missing.isEmpty { return decoded }
            var merged = decoded
            merged.append(contentsOf: missing)
            saveLocked(merged)
            return merged
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
