import Foundation

// MARK: - ACPAgentConfiguration

/// Launch configuration for an external ACP agent process.
/// Persisted in preferences as a command line; holds no secrets.
public struct ACPAgentConfiguration: Sendable, Equatable {
    /// Absolute path of the agent executable, e.g. `/opt/homebrew/bin/gemini`.
    public var command: String
    /// Command line arguments passed to the executable.
    public var arguments: [String]
    /// Working directory for the agent process, used as the session cwd.
    public var workingDirectory: String?
    /// Extra environment variables merged over the inherited environment.
    public var environment: [String: String]
    /// Optional text prepended to the first user message of a session.
    /// ACP has no system prompt field, so this is passthrough on the client side.
    public var systemPrompt: String?

    public init(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        systemPrompt: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.systemPrompt = systemPrompt
    }

    /// Basename of `command`, e.g. "gemini", "claude".
    public var agentName: String {
        (command as NSString).lastPathComponent
    }
}

// MARK: - Wire message model

/// Identifier used to correlate JSON-RPC requests with responses.
public enum ACPRequestID: Hashable, Sendable {
    case int(Int)
    case string(String)

    var wireValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    static func from(_ raw: Any?) -> ACPRequestID? {
        switch raw {
        case let value as Int: return .int(value)
        case let value as Double: return .int(Int(value))
        case let value as String: return .string(value)
        default: return nil
        }
    }
}

/// One decoded JSON-RPC message from the agent, tolerant of unknown shapes.
public enum ACPWireMessage: Sendable {
    /// A response fulfilling a request we sent.
    case response(id: ACPRequestID, result: [String: Any]?)
    /// A response rejecting a request we sent.
    case errorResponse(id: ACPRequestID, code: Int, message: String)
    /// A server-initiated request expecting a response from us.
    case request(id: ACPRequestID, method: String, params: [String: Any]?)
    /// A fire-and-forget notification, e.g. `session/update`.
    case notification(method: String, params: [String: Any]?)
}

/// Encodes outgoing and decodes incoming JSON-RPC 2.0 lines for ACP.
/// Malformed input decodes to nil instead of throwing so one bad agent
/// line never kills the reader loop.
public enum ACPJSONRPC {

    /// Decodes one line of agent output. Returns nil for blank or invalid JSON.
    public static func decodeLine(_ line: String) -> ACPWireMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Notifications carry method without id; requests carry both.
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any]
            if let id = ACPRequestID.from(object["id"]) {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        guard let id = ACPRequestID.from(object["id"]) else { return nil }
        if let error = object["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let message = error["message"] as? String {
            return .errorResponse(id: id, code: code, message: message)
        }
        return .response(id: id, result: object["result"] as? [String: Any])
    }

    /// Encodes a request we send to the agent.
    public static func encodeRequest(
        id: ACPRequestID,
        method: String,
        params: [String: Any]? = nil
    ) throws -> String {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.wireValue,
            "method": method
        ]
        if let params { object["params"] = params }
        return try encodeObject(object)
    }

    /// Encodes a notification we send to the agent (no id, no response).
    public static func encodeNotification(
        method: String,
        params: [String: Any]? = nil
    ) throws -> String {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params { object["params"] = params }
        return try encodeObject(object)
    }

    /// Encodes a successful response to an agent-initiated request.
    public static func encodeResponse(id: ACPRequestID, result: [String: Any]) throws -> String {
        try encodeObject([
            "jsonrpc": "2.0",
            "id": id.wireValue,
            "result": result
        ])
    }

    /// Encodes an error response to an agent-initiated request we cannot serve.
    public static func encodeErrorResponse(
        id: ACPRequestID,
        code: Int,
        message: String
    ) throws -> String {
        try encodeObject([
            "jsonrpc": "2.0",
            "id": id.wireValue,
            "error": ["code": code, "message": message]
        ])
    }

    /// Builds the polite v1 rejection for `session/request_permission`.
    /// The current ACP v1 schema has no "rejected" outcome; the polite deny is
    /// to select the reject option the agent itself advertised, and fall back
    /// to the "cancelled" outcome when it advertised none, so agents never
    /// block waiting on a UI we do not have.
    public static func encodePermissionRejection(
        id: ACPRequestID,
        params: [String: Any]?
    ) throws -> String {
        let options = (params?["options"] as? [[String: Any]]) ?? []
        let rejectOption = options.first { option in
            guard let kind = option["kind"] as? String else { return false }
            return kind.hasPrefix("reject")
        }
        let outcome: [String: Any]
        if let optionId = rejectOption?["optionId"] as? String {
            outcome = ["outcome": "selected", "optionId": optionId]
        } else {
            outcome = ["outcome": "cancelled"]
        }
        return try encodeResponse(id: id, result: ["outcome": outcome])
    }

    /// Encodes the `initialize` request for ACP v1.
    public static func encodeInitializeRequest(id: ACPRequestID) throws -> String {
        try encodeRequest(
            id: id,
            method: "initialize",
            params: [
                "protocolVersion": "1",
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false]
                ],
                "clientInfo": ["name": "BusinessBar", "title": "BusinessBar", "version": "1"]
            ]
        )
    }

    private static func encodeObject(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let line = String(data: data, encoding: .utf8) else {
            throw ACPJSONRPCError.encodingFailed
        }
        return line
    }
}

/// Errors thrown by the codec.
public enum ACPJSONRPCError: Error {
    case encodingFailed
}

// MARK: - Update mapping

/// Accumulates `session/update` text chunks and turns them into
/// `CompanionEvent` values, so the mapping is testable without a process.
public struct ACPUpdateMapper {

    /// Full assistant text accumulated from `agent_message_chunk` updates.
    public private(set) var accumulatedText: String

    public init() {
        self.accumulatedText = ""
    }

    /// Maps one `session/update` notification params dictionary to the deltas
    /// it should emit. Non-text content blocks (image, resource_link, tool
    /// call content) are ignored gracefully. Plan and tool call updates emit
    /// no companion events in v1; the agent owns its tools.
    public mutating func events(forUpdate params: [String: Any]?) -> [CompanionEvent] {
        guard let update = params?["update"] as? [String: Any],
              let sessionUpdate = update["sessionUpdate"] as? String,
              sessionUpdate == "agent_message_chunk"
        else { return [] }

        let blocks = (update["content"] as? [[String: Any]]) ?? []
        var deltas: [CompanionEvent] = []
        for block in blocks {
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String
            else { continue }
            accumulatedText += text
            deltas.append(.delta(text))
        }
        return deltas
    }

    /// Terminal event for a completed `session/prompt` turn.
    /// `stopReason` "cancelled" maps to `.cancelled`; anything else the agent
    /// reports as a completed turn maps to `.finished` with the full text.
    public func terminalEvent(stopReason: String?) -> CompanionEvent {
        if stopReason == "cancelled" {
            return .cancelled
        }
        return .finished(fullText: accumulatedText)
    }
}