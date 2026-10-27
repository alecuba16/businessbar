import Foundation

// MARK: - OpenAICompatClient

/// Streaming client for OpenAI-compatible `/chat/completions` endpoints.
/// Works with OpenAI, Anthropic's compat endpoint, Gemini's compat endpoint,
/// Ollama, LM Studio, OpenRouter and any other server that speaks the same
/// SSE wire format.
///
/// Design notes:
/// - One `URLSession` shared across calls; streaming uses `URLSession.bytes`
///   so no delegate plumbing is needed.
/// - Tool calling is supported through `onToolCall`: when the model requests
///   an advertised tool, the client pauses the stream, asks the callback for
///   the tool output, appends the tool exchange to the conversation and
///   requests a follow-up completion.
/// - Terminal events (`finished`/`failed`/`cancelled`) are emitted exactly
///   once per `stream` call.
public final class OpenAICompatClient: LLMClient, @unchecked Sendable {
    public let name: String

    private let configuration: CompanionConfiguration
    private let session: URLSession
    private let maxToolRounds: Int

    /// Advertised tools (JSON schema definitions, OpenAI format).
    /// Empty by default: no tools are offered to the model.
    private let tools: [[String: Any]]
    private let storedToolHandler: ((String, String) async -> String)?

    public init(
        configuration: CompanionConfiguration,
        name: String = "OpenAI-compatible",
        tools: [[String: Any]] = [],
        toolHandler: ((String, String) async -> String)? = nil,
        maxToolRounds: Int = 3,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.name = name
        self.tools = tools
        self.storedToolHandler = toolHandler
        self.maxToolRounds = maxToolRounds
        self.session = session
    }

    public func stream(
        messages: [ChatMessage],
        onToolCall: ((String, String) async -> String)? = nil,
        reasoningEffortOverride: String? = nil
    ) async -> AsyncThrowingStream<CompanionEvent, Error> {
        let configuration = self.configuration
        let tools = self.tools
        let maxToolRounds = self.maxToolRounds
        let session = self.session
        let toolHandler = onToolCall ?? storedToolHandler
        // Per-request effort wins over the configured one; template
        // overrides and chat-panel ad-hoc picks both land here.
        let effort = reasoningEffortOverride ?? configuration.reasoningEffort

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { (continuation: AsyncThrowingStream<CompanionEvent, Error>.Continuation) in
            let task = Task {
                var workingMessages = messages
                if !configuration.systemPrompt.isEmpty {
                    workingMessages.insert(
                        ChatMessage(role: .system, content: configuration.systemPrompt),
                        at: 0
                    )
                }

                var toolRounds = 0
                streamLoop: while true {
                    // Build the request body.
                    var body: [String: Any] = [
                        "model": configuration.model,
                        "stream": true,
                        "messages": workingMessages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools
                    }
                    if configuration.reasoning, let effort, !effort.isEmpty {
                        body["reasoning_effort"] = effort
                    }

                    guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
                        continuation.yield(.failed("Could not encode request body."))
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: configuration.baseURL
                        .appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
                    for (name, value) in configuration.extraHeaders {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    request.httpBody = payload
                    request.timeoutInterval = 120

                    do {
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            continuation.yield(.failed("Unexpected non-HTTP response."))
                            continuation.finish()
                            return
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let bodyText = await Self.errorBodyText(bytes)
                            continuation.yield(.failed(
                                "Server returned \(http.statusCode). \(bodyText)"))
                            continuation.finish()
                            return
                        }

                        var accumulated = ""
                        var pendingToolCalls: [ToolCallAccumulator] = []

                        for try await line in bytes.lines {
                            guard Task.isCancelled == false else { break }
                            guard line.hasPrefix("data:") else { continue }
                            let dataString = line
                                .dropFirst("data:".count)
                                .trimmingCharacters(in: .whitespaces)

                            if dataString == "[DONE]" { break }

                            guard let data = dataString.data(using: .utf8),
                                  let chunk = try? JSONSerialization.jsonObject(with: data)
                                      as? [String: Any],
                                  let choice = (chunk["choices"] as? [[String: Any]])?.first
                            else { continue }

                            if let delta = choice["delta"] as? [String: Any] {
                                if let text = delta["content"] as? String, !text.isEmpty {
                                    accumulated += text
                                    continuation.yield(.delta(text))
                                }
                                // Reasoning models behind OpenAI-compatible gateways
                                // stream their reasoning in either field
                                // depending on the vendor; both go to the
                                // thinking block, never the answer.
                                let reasoning = (delta["reasoning"] as? String)
                                    ?? (delta["reasoning_content"] as? String)
                                if let piece = reasoning, !piece.isEmpty {
                                    continuation.yield(.thinkingDelta(piece))
                                }
                                if let toolChunks = delta["tool_calls"] as? [[String: Any]] {
                                    ToolCallAccumulator.merge(into: &pendingToolCalls, chunks: toolChunks)
                                }
                            }

                            if let finish = choice["finish_reason"] as? String,
                               finish == "tool_calls" {
                                break
                            }
                        }

                        if Task.isCancelled {
                            continuation.yield(.cancelled)
                            continuation.finish()
                            return
                        }

                        if !pendingToolCalls.isEmpty {
                            guard let toolHandler, toolRounds < maxToolRounds else {
                                let message = toolRounds >= maxToolRounds
                                    ? "Tool round limit reached before the model produced a final answer."
                                    : "The model requested a tool but no tool handler is available."
                                continuation.yield(.failed(message))
                                continuation.finish()
                                return
                            }
                            toolRounds += 1

                            // Feed the assistant's tool request back into the conversation.
                            workingMessages.append(ChatMessage(role: .assistant, content: accumulated))
                            for call in pendingToolCalls {
                                let output = await toolHandler(call.name, call.arguments)
                                // OpenAI tool role expects the tool call id.
                                let toolMessage = ChatMessage(
                                    role: .user,
                                    content: "Tool '\(call.name)' returned:\n\(output)"
                                )
                                workingMessages.append(toolMessage)
                                continuation.yield(.toolCallRequested(
                                    name: call.name, argumentsJSON: call.arguments))
                            }
                            continue streamLoop
                        }

                        continuation.yield(.finished(fullText: accumulated))
                        continuation.finish()
                        return
                    } catch let error as URLError where error.code == .cancelled {
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    } catch {
                        continuation.yield(.failed(
                            "Request failed: \(error.localizedDescription)"))
                        continuation.finish()
                        return
                    }
                }
            }

            continuation.onTermination = { @Sendable (termination: AsyncThrowingStream<CompanionEvent, Error>.Continuation.Termination) in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    private static func errorBodyText(_ bytes: URLSession.AsyncBytes) async -> String {
        var collected: [UInt8] = []
        var iterator = bytes.makeAsyncIterator()
        // Read a bounded number of bytes; error bodies can be huge.
        while let byte = try? await iterator.next(), collected.count < 300 {
            collected.append(byte)
        }
        return String(decoding: collected, as: UTF8.self)
    }
}

// MARK: - ToolCallAccumulator

/// Tool calls arrive fragmented across stream chunks (id and name first,
/// arguments split into index-ordered pieces). This merges them back into
/// complete calls.
private struct ToolCallAccumulator {
    let name: String
    let arguments: String

    static func merge(into pending: inout [ToolCallAccumulator], chunks: [[String: Any]]) {
        for chunk in chunks {
            let index = chunk["index"] as? Int ?? pending.count
            let function = chunk["function"] as? [String: Any] ?? [:]
            let namePart = function["name"] as? String ?? ""
            let argsPart = function["arguments"] as? String ?? ""

            while pending.count <= index {
                pending.append(ToolCallAccumulator(name: "", arguments: ""))
            }
            var updated = pending[index]
            if !namePart.isEmpty { updated = ToolCallAccumulator(name: namePart, arguments: updated.arguments) }
            if !argsPart.isEmpty {
                updated = ToolCallAccumulator(name: updated.name, arguments: updated.arguments + argsPart)
            }
            pending[index] = updated
        }
    }
}