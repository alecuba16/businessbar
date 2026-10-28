import Foundation

// MARK: - ACPAgentClient

/// `LLMClient` backed by an external ACP agent process.
///
/// Session strategy: one persistent session per agent lifetime, created lazily
/// on the first `stream` call. Subsequent `stream` calls continue that session
/// (multi-turn chat). ACP agents own their conversation history, so only the
/// latest user message in `messages` is sent with `session/prompt`; earlier
/// messages are ignored on the wire. `systemPrompt`, when configured, is
/// prepended to the first user prompt of the session because ACP v1 has no
/// dedicated system prompt field.
///
/// The agent process is spawned on the first `stream` call and stays alive
/// across turns; call `shutdown()` when the chat panel closes to kill it.
public final class ACPAgentClient: LLMClient, @unchecked Sendable {

    public let name: String

    private let configuration: ACPAgentConfiguration
    private let transportFactory: @Sendable (ACPAgentConfiguration) -> ACPTransport

    private let lock = NSLock()
    private var transport: ACPTransport?
    private var nextRequestIDValue = 1
    private var sessionId: String?
    private var pendingPrompts: [ACPRequestID: CheckedContinuation<PromptOutcome, Error>] = [:]
    private var pendingHandshakes: [ACPRequestID: CheckedContinuation<[String: Any]?, Error>] = [:]
    private var activeUpdateHandler: (@Sendable ([CompanionEvent]) -> Void)?
    private var processClosed = false
    private var spawnTask: Task<Void, Error>?
    private var spawnWaiters: [CheckedContinuation<Void, Error>] = []

    /// Outcome of one `session/prompt` turn.
    private enum PromptOutcome: Sendable {
        case stopped(stopReason: String?)
        case failed(String)
    }

    /// Creates a client for the agent described by `configuration`.
    /// Pass a custom `transportFactory` only in tests.
    public init(
        configuration: ACPAgentConfiguration,
        transportFactory: @escaping @Sendable (ACPAgentConfiguration) -> ACPTransport = { ACPStdioTransport(configuration: $0) }
    ) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.name = configuration.agentName
    }

    // MARK: LLMClient

    /// Streams a completion for the latest user message in `messages`.
    /// `onToolCall` is unused: ACP agents execute their own tools, so it is
    /// never invoked and tools never surface as companion events in v1.
    /// `reasoningEffortOverride` is unused for the same reason: the agent
    /// subprocess owns its reasoning configuration.
    public func stream(
        messages: [ChatMessage],
        onToolCall: ((String, String) async -> String)?,
        reasoningEffortOverride: String?
    ) async -> AsyncThrowingStream<CompanionEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { (continuation: AsyncThrowingStream<CompanionEvent, Error>.Continuation) in
            let client = self
            let promptText = messages.last(where: { $0.role == .user })?.content ?? ""
            let task = Task {
                do {
                    try await client.ensureConnection()
                    let sessionID = try await client.ensureSession()
                    let mappedPrompt = client.mappedPrompt(for: promptText)

                    client.lock.lock()
                    client.activeUpdateHandler = { events in
                        for event in events { continuation.yield(event) }
                    }
                    client.lock.unlock()

                    let outcome = try await client.sendPrompt(
                        sessionId: sessionID,
                        promptText: mappedPrompt
                    )

                    client.lock.lock()
                    client.activeUpdateHandler = nil
                    client.lock.unlock()

                    switch outcome {
                    case .stopped(let stopReason):
                        continuation.yield(client.finishTerminalEvent(stopReason: stopReason))
                    case .failed(let message):
                        continuation.yield(.failed(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { (termination: AsyncThrowingStream<CompanionEvent, Error>.Continuation.Termination) in
                if case .cancelled = termination {
                    Task { await client.cancelActivePrompt() }
                }
                task.cancel()
            }
        }
    }

    /// Terminal event honoring the mapper's accumulated text and the stop
    /// reason, or cancellation when the consumer stopped listening.
    private func finishTerminalEvent(stopReason: String?) -> CompanionEvent {
        lock.lock()
        let text = accumulatedTextStorage
        lock.unlock()
        if stopReason == "cancelled" {
            return .cancelled
        }
        return .finished(fullText: text)
    }

    // MARK: Shutdown

    /// Cancels any in-flight prompt via `session/cancel`, terminates the agent
    /// process, and invalidates the session so the next `stream` respawns.
    /// Safe to call from the main actor.
    public func shutdown() async {
        lock.lock()
        let transport = self.transport
        let sessionID = self.sessionId
        let hadPrompt = !self.pendingPrompts.isEmpty
        self.sessionId = nil
        self.processClosed = true
        self.transport = nil
        self.accumulatedTextStorage = ""
        lock.unlock()

        if let transport, let sessionID, hadPrompt {
            if let line = try? ACPJSONRPC.encodeNotification(
                method: "session/cancel",
                params: ["sessionId": sessionID]
            ) {
                try? await transport.send(line)
            }
        }
        await transport?.stop()
    }

    deinit {
        if let transport {
            let processTransport = transport
            Task { await processTransport.stop() }
        }
    }

    /// Synchronous shutdown for application termination: async tasks may
    /// never run before the process exits, so this terminates the agent
    /// inline and invalidates the session. Skips the session/cancel round
    /// trip; the OS reaps the agent either way at quit time.
    public func terminateNow() {
        lock.lock()
        let transport = self.transport
        self.transport = nil
        self.sessionId = nil
        self.processClosed = true
        lock.unlock()

        if let stdio = transport as? ACPStdioTransport {
            stdio.terminateNow()
        }
    }

    // MARK: Connection lifecycle

    /// Spawns the process and completes the `initialize` handshake.
    private func ensureConnection() async throws {
        lock.lock()
        if let existingTransport = transport, !processClosed {
            lock.unlock()
            return
        }
        processClosed = false
        if let spawnTask {
            // A spawn is already in flight: wait for it instead of racing
            // a second process into existence.
            lock.unlock()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                spawnWaiters.append(cont)
                lock.unlock()
            }
            return
        }
        let transport = transportFactory(configuration)
        self.transport = transport
        lock.unlock()

        let spawnedTask = Task<Void, Error> {
            try await transport.start(onMessage: { [weak self] message in
                self?.route(message)
            }, onClose: { [weak self] in
                self?.handleProcessClosed()
            })

            let initializeID = self.allocateRequestID()
            let line = try ACPJSONRPC.encodeInitializeRequest(id: initializeID)
            try await transport.send(line)
            let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any]?, Error>) in
                lock.lock()
                pendingHandshakes[initializeID] = cont
                lock.unlock()
            }
            if result == nil {
                throw ACPError.malformedResponse("initialize response missing result")
            }
        }
        lock.lock()
        self.spawnTask = spawnedTask
        lock.unlock()

        do {
            try await spawnedTask.value
        } catch {
            lock.lock()
            self.spawnTask = nil
            self.transport = nil
            let waiters = spawnWaiters
            spawnWaiters = []
            lock.unlock()
            for waiter in waiters { waiter.resume(throwing: error) }
            await transport.stop()
            throw error
        }

        lock.lock()
        self.spawnTask = nil
        let waiters = spawnWaiters
        spawnWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Creates the persistent session on first use, reusing it afterwards.
    private func ensureSession() async throws -> String {
        lock.lock()
        if let sessionId, !processClosed {
            lock.unlock()
            return sessionId
        }
        lock.unlock()

        let requestID = allocateRequestID()
        var params: [String: Any] = [
            "cwd": configuration.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "mcpServers": []
        ]
        if let initialPrompt = configuration.systemPrompt {
            params["sessionInitRequest"] = ["field": initialPrompt]
        }
        let line = try ACPJSONRPC.encodeRequest(id: requestID, method: "session/new", params: params)
        let transport = try await currentTransport()
        try await transport.send(line)
        let result: [String: Any]? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any]?, Error>) in
            lock.lock()
            pendingHandshakes[requestID] = cont
            lock.unlock()
        }
        guard let sessionID = result?["sessionId"] as? String else {
            throw ACPError.malformedResponse("session/new response missing sessionId")
        }
        lock.lock()
        sessionId = sessionID
        lock.unlock()
        return sessionID
    }

    private func currentTransport() async throws -> ACPTransport {
        try await ensureConnection()
        lock.lock()
        defer { lock.unlock() }
        return transport!
    }

    /// First prompt of a session carries the system prompt passthrough.
    private func mappedPrompt(for text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if systemPromptPending, let systemPrompt = configuration.systemPrompt, !systemPrompt.isEmpty {
            systemPromptPending = false
            return systemPrompt + "\n\n" + text
        }
        return text
    }

    /// Sends one `session/prompt` and awaits its terminal outcome while
    /// `session/update` notifications stream deltas through the continuation.
    private func sendPrompt(
        sessionId sessionID: String,
        promptText: String
    ) async throws -> PromptOutcome {
        lock.lock()
        accumulatedTextStorage = ""
        lock.unlock()

        let requestID = allocateRequestID()
        let params: [String: Any] = [
            "sessionId": sessionID,
            "prompt": [[ "type": "text", "text": promptText ]]
        ]
        let line = try ACPJSONRPC.encodeRequest(id: requestID, method: "session/prompt", params: params)
        let transport = try await currentTransport()
        try await transport.send(line)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PromptOutcome, Error>) in
                lock.lock()
                pendingPrompts[requestID] = cont
                lock.unlock()
            }
        } onCancel: {
            Task { await self.cancelActivePrompt() }
        }
    }

    /// Sends `session/cancel` for the in-flight turn and resolves its
    /// continuation locally with a cancelled outcome. Only the prompt turn
    /// is cancelled; the process stays alive.
    private func cancelActivePrompt() async {
        lock.lock()
        let pending = pendingPrompts
        pendingPrompts = [:]
        let sessionID = sessionId
        let transport = self.transport
        lock.unlock()

        guard !pending.isEmpty else { return }
        if let sessionID, let transport,
           let line = try? ACPJSONRPC.encodeNotification(
               method: "session/cancel",
               params: ["sessionId": sessionID]
           ) {
            try? await transport.send(line)
        }
        for cont in pending.values {
            cont.resume(returning: .stopped(stopReason: "cancelled"))
        }
    }

    // MARK: Inbound routing

    private func route(_ message: ACPWireMessage) {
        switch message {
        case .notification(let method, let params):
            guard method == "session/update" else { return }
            lock.lock()
            var mapper = accumulatedMapper
            let events = mapper.events(forUpdate: params)
            accumulatedMapper = mapper
            accumulatedTextStorage = mapper.accumulatedText
            let handler = activeUpdateHandler
            lock.unlock()
            handler?(events)

        case .response(let id, let result):
            // Both request kinds resolve here: handshakes (initialize,
            // session/new) and prompt turns. The stop reason rides in the
            // result payload; agents that omit it still end the turn.
            lock.lock()
            let promptCont = pendingPrompts[id]
            pendingPrompts[id] = nil
            lock.unlock()
            if let promptCont {
                promptCont.resume(returning: .stopped(stopReason: result?["stopReason"] as? String))
            } else {
                resume(handshake: id, with: .success(result))
            }

        case .errorResponse(let id, let code, let message):
            resume(handshake: id, with: .failure(ACPError.agentError(code: code, message: message)))
            lock.lock()
            let pending = pendingPrompts[id]
            pendingPrompts[id] = nil
            lock.unlock()
            pending?.resume(returning: .failed(message))

        case .request(let id, let method, let params):
            // v1 has no permission UI: decline politely so agents do not hang.
            // Requests we cannot serve get a standard JSON-RPC error instead
            // of silence.
            Task { [weak self] in
                guard let self else { return }
                let line: String?
                switch method {
                case "session/request_permission":
                    line = try? ACPJSONRPC.encodePermissionRejection(id: id, params: params)
                default:
                    line = try? ACPJSONRPC.encodeErrorResponse(
                        id: id,
                        code: -32601,
                        message: "Method not supported by BusinessBar"
                    )
                }
                if let line {
                    lock.lock()
                    let transport = self.transport
                    lock.unlock()
                    if let transport {
                        try? await transport.send(line)
                    }
                }
            }
        }
    }

    private func resume(
        handshake id: ACPRequestID,
        with result: Result<[String: Any]?, Error>
    ) {
        lock.lock()
        let cont = pendingHandshakes[id]
        pendingHandshakes[id] = nil
        lock.unlock()
        switch result {
        case .success(let value): cont?.resume(returning: value)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    /// Process exit mid-stream fails any waiting turn and clears the session.
    private func handleProcessClosed() {
        lock.lock()
        let prompts = pendingPrompts
        pendingPrompts = [:]
        let handshakes = pendingHandshakes
        pendingHandshakes = [:]
        let waiters = spawnWaiters
        spawnWaiters = []
        let handler = activeUpdateHandler
        activeUpdateHandler = nil
        sessionId = nil
        transport = nil
        lock.unlock()

        for cont in prompts.values {
            cont.resume(returning: .failed("Agent process exited"))
        }
        for cont in handshakes.values {
            cont.resume(throwing: ACPError.processExited)
        }
        for waiter in waiters {
            waiter.resume(throwing: ACPError.processExited)
        }
        handler?([.failed("Agent process exited")])
    }

    // MARK: Shared state

    private var accumulatedMapper = ACPUpdateMapper()
    private var accumulatedTextStorage: String = ""
    private var systemPromptPending = true

    private func allocateRequestID() -> ACPRequestID {
        lock.lock()
        defer { lock.unlock() }
        let id = nextRequestIDValue
        nextRequestIDValue += 1
        return .int(id)
    }

    /// Diagnostics: last stderr lines from the agent process.
    public var recentStderr: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let transport = transport as? ACPStdioTransport {
            return transport.recentStderr
        }
        return []
    }
}

/// Client-side ACP failure reasons surfaced through `.failed` events.
public enum ACPError: Error {
    case agentError(code: Int, message: String)
    case processExited
    case malformedResponse(String)
}