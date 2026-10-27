import Foundation

// MARK: - ChatMessage

/// One message in a companion conversation.
public struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public var id: UUID
    public var role: Role
    public var content: String

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

// MARK: - CompanionEvent

/// Streamed events emitted by an LLM client while completing a prompt.
public enum CompanionEvent: Sendable {
    /// Partial assistant text appended to the running response.
    case delta(String)
    /// The model requested a tool call (e.g. web search). `name` identifies it.
    case toolCallRequested(name: String, argumentsJSON: String)
    /// Terminal success. `fullText` is the complete assistant response.
    case finished(fullText: String)
    /// Terminal failure with a user-presentable message.
    case failed(String)
    /// The request was cancelled before finishing.
    case cancelled
}

// MARK: - LLMClient

/// Backend-agnostic interface for completing companion prompts.
/// Implementations stream updates through the returned AsyncSequence and
/// return terminal events exactly once (`finished`, `failed`, or `cancelled`).
public protocol LLMClient: Sendable {
    /// Human-presentable name for logs and settings UI.
    var name: String { get }

    /// Streams a completion for `messages`.
    /// `onToolCall` is invoked when the model requests a tool the client
    /// advertised; its return value is fed back into the conversation before
    /// continuing the stream. Pass `nil` when the backend advertises no tools.
    func stream(
        messages: [ChatMessage],
        onToolCall: ((String, String) async -> String)?
    ) async -> AsyncThrowingStream<CompanionEvent, Error>
}

// MARK: - CompanionConfiguration

/// User configuration for the OpenAI-compatible backend.
public struct CompanionConfiguration: Sendable, Equatable {
    /// Base URL of an OpenAI-compatible API, e.g. `https://api.openai.com/v1`.
    public var baseURL: URL
    /// Model identifier, e.g. `gpt-4o-mini`.
    public var model: String
    /// API key. Stored in the Keychain by the app layer, never in UserDefaults.
    public var apiKey: String
    /// Optional system prompt prepended to every conversation.
    public var systemPrompt: String
    /// True when the model reasons before answering. Gates `reasoningEffort`.
    public var reasoning: Bool
    /// Effort sent as `reasoning_effort` when `reasoning` is true.
    public var reasoningEffort: String?
    /// Extra HTTP headers added to every chat request. Keys named here win
    /// over the built-in `Authorization` header, so gateways with their own
    /// auth schemes stay usable.
    public var extraHeaders: [String: String]

    public init(
        baseURL: URL,
        model: String,
        apiKey: String,
        systemPrompt: String = "",
        reasoning: Bool = false,
        reasoningEffort: String? = nil,
        extraHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.reasoning = reasoning
        self.reasoningEffort = reasoningEffort
        self.extraHeaders = extraHeaders
    }

    public static let `default` = CompanionConfiguration(
        baseURL: URL(string: "https://api.openai.com/v1")!,
        model: "gpt-4o-mini",
        apiKey: ""
    )
}