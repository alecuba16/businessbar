import XCTest
@testable import BusinessBarCore

// MARK: - Codec tests

final class ACPJSONRPCTests: XCTestCase {

    func testDecodeResponseWithResult() {
        let message = ACPJSONRPC.decodeLine(#"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s1"}}"#)
        guard case .response(let id, let result) = message else {
            XCTFail("Expected response, got \(String(describing: message))")
            return
        }
        XCTAssertEqual(id, .int(3))
        XCTAssertEqual(result?["sessionId"] as? String, "s1")
    }

    func testDecodeErrorResponse() {
        let message = ACPJSONRPC.decodeLine(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"nope"}}"#)
        guard case .errorResponse(let id, let code, let text) = message else {
            XCTFail("Expected error response, got \(String(describing: message))")
            return
        }
        XCTAssertEqual(id, .int(7))
        XCTAssertEqual(code, -32601)
        XCTAssertEqual(text, "nope")
    }

    func testDecodeNotificationWithoutID() {
        let message = ACPJSONRPC.decodeLine(#"{"jsonrpc":"2.0","method":"session/update","params":{"update":{}}}"#)
        guard case .notification(let method, _) = message else {
            XCTFail("Expected notification, got \(String(describing: message))")
            return
        }
        XCTAssertEqual(method, "session/update")
    }

    func testDecodeServerRequestWithID() {
        let message = ACPJSONRPC.decodeLine(#"{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{}}"#)
        guard case .request(let id, let method, _) = message else {
            XCTFail("Expected request, got \(String(describing: message))")
            return
        }
        XCTAssertEqual(id, .string("perm-1"))
        XCTAssertEqual(method, "session/request_permission")
    }

    func testDecodeToleratesMalformedLines() {
        for bad in ["", "   ", "not json", "[1,2]", #"{"jsonrpc":"2.0"}"#] {
            XCTAssertNil(ACPJSONRPC.decodeLine(bad), "Expected nil for line: \(bad)")
        }
    }

    func testEncodeRequestRoundTripsThroughDecode() throws {
        let line = try ACPJSONRPC.encodeRequest(id: .int(42), method: "session/new", params: ["cwd": "/tmp"])
        guard case .request(let id, let method, let params) = ACPJSONRPC.decodeLine(line) else {
            XCTFail("Encoded request did not decode back")
            return
        }
        XCTAssertEqual(id, .int(42))
        XCTAssertEqual(method, "session/new")
        XCTAssertEqual(params?["cwd"] as? String, "/tmp")
    }

    func testEncodeNotificationHasNoID() throws {
        let line = try ACPJSONRPC.encodeNotification(method: "session/cancel", params: ["sessionId": "s1"])
        guard case .notification(let method, let params) = ACPJSONRPC.decodeLine(line) else {
            XCTFail("Encoded notification did not decode back")
            return
        }
        XCTAssertEqual(method, "session/cancel")
        XCTAssertEqual(params?["sessionId"] as? String, "s1")
    }

    func testPermissionRejectionSelectsRejectOption() throws {
        let params: [String: Any] = [
            "options": [
                ["optionId": "opt-allow", "kind": "allow_always"],
                ["optionId": "opt-reject", "kind": "reject_once"]
            ]
        ]
        let line = try ACPJSONRPC.encodePermissionRejection(id: .int(5), params: params)
        guard case .response(let id, let result) = ACPJSONRPC.decodeLine(line) else {
            XCTFail("Expected response, got \(line)")
            return
        }
        XCTAssertEqual(id, .int(5))
        let outcome = result?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["outcome"] as? String, "selected")
        XCTAssertEqual(outcome?["optionId"] as? String, "opt-reject")
    }

    func testPermissionRejectionFallsBackToCancelled() throws {
        let line = try ACPJSONRPC.encodePermissionRejection(id: .int(6), params: [
            "options": [["optionId": "opt-allow", "kind": "allow_once"]]
        ])
        guard case .response(_, let result) = ACPJSONRPC.decodeLine(line) else {
            XCTFail("Expected response, got \(line)")
            return
        }
        let outcome = result?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["outcome"] as? String, "cancelled")
    }

    func testInitializeRequestShape() throws {
        let line = try ACPJSONRPC.encodeInitializeRequest(id: .int(1))
        guard case .request(_, let method, let params) = ACPJSONRPC.decodeLine(line) else {
            XCTFail("Expected request, got \(line)")
            return
        }
        XCTAssertEqual(method, "initialize")
        XCTAssertEqual(params?["protocolVersion"] as? String, "1")
        let capabilities = params?["clientCapabilities"] as? [String: Any]
        let fs = capabilities?["fs"] as? [String: Any]
        XCTAssertEqual(fs?["readTextFile"] as? Bool, false)
        XCTAssertEqual(fs?["writeTextFile"] as? Bool, false)
    }
}

// MARK: - Chunk mapping tests

final class ACPUpdateMapperTests: XCTestCase {

    private func messageChunk(_ text: String) -> [String: Any] {
        [
            "sessionId": "s1",
            "update": [
                "sessionUpdate": "agent_message_chunk",
                "content": [["type": "text", "text": text]]
            ]
        ]
    }

    private func thoughtChunk(_ text: String) -> [String: Any] {
        [
            "sessionId": "s1",
            "update": [
                "sessionUpdate": "agent_thought_chunk",
                "content": ["type": "text", "text": text]
            ]
        ]
    }

    func testChunkSequenceAccumulatesAndFinishes() {
        var mapper = ACPUpdateMapper()
        var deltas: [String] = []
        for params in [messageChunk("Hello"), messageChunk(" "), messageChunk("world")] {
            for event in mapper.events(forUpdate: params) {
                guard case .delta(let piece) = event else {
                    XCTFail("Expected delta, got \(event)")
                    continue
                }
                deltas.append(piece)
            }
        }
        XCTAssertEqual(deltas, ["Hello", " ", "world"])
        XCTAssertEqual(mapper.accumulatedText, "Hello world")
        guard case .finished(let fullText) = mapper.terminalEvent(stopReason: "end_turn") else {
            XCTFail("Expected finished event")
            return
        }
        XCTAssertEqual(fullText, "Hello world")
    }

    func testNonTextBlocksAreIgnored() {
        var mapper = ACPUpdateMapper()
        let params: [String: Any] = [
            "sessionId": "s1",
            "update": [
                "sessionUpdate": "agent_message_chunk",
                "content": [
                    ["type": "image", "data": "..." ],
                    ["type": "text", "text": "kept"]
                ]
            ]
        ]
        let events = mapper.events(forUpdate: params)
        XCTAssertEqual(events.count, 1)
        guard case .delta(let piece) = events.first else {
            XCTFail("Expected one delta")
            return
        }
        XCTAssertEqual(piece, "kept")
        XCTAssertEqual(mapper.accumulatedText, "kept")
    }

    func testResourceLinkBecomesMarkdownLink() {
        var mapper = ACPUpdateMapper()
        let params: [String: Any] = [
            "sessionId": "s1",
            "update": [
                "sessionUpdate": "agent_message_chunk",
                "content": [
                    ["type": "resource_link", "name": "report.md", "uri": "file:///tmp/report.md"],
                    ["type": "resource_link", "title": "Docs", "name": "ignored", "uri": "https://example.com"]
                ]
            ]
        ]
        let events = mapper.events(forUpdate: params)
        XCTAssertEqual(events.count, 2)
        guard case .delta(let first) = events.first else {
            XCTFail("Expected delta for resource_link")
            return
        }
        XCTAssertEqual(first, "[report.md](file:///tmp/report.md)")
        guard case .delta(let second) = events.last else {
            XCTFail("Expected delta for resource_link")
            return
        }
        XCTAssertEqual(second, "[Docs](https://example.com)")
        XCTAssertEqual(mapper.accumulatedText, "[report.md](file:///tmp/report.md)[Docs](https://example.com)")
    }

    func testResourceLinkWithoutTitleOrNameUsesURI() {
        var mapper = ACPUpdateMapper()
        let params: [String: Any] = [
            "sessionId": "s1",
            "update": [
                "sessionUpdate": "agent_message_chunk",
                "content": [["type": "resource_link", "uri": "https://example.com/a"]]
            ]
        ]
        let events = mapper.events(forUpdate: params)
        XCTAssertEqual(events.count, 1)
        guard case .delta(let piece) = events.first else {
            XCTFail("Expected delta")
            return
        }
        XCTAssertEqual(piece, "[https://example.com/a](https://example.com/a)")
    }

    func testResourceLinkWithoutURIIsIgnored() {
        var mapper = ACPUpdateMapper()
        let params: [String: Any] = [
            "sessionId": "s1",
            "update": [
                "sessionUpdate": "agent_message_chunk",
                "content": [["type": "resource_link", "name": "no uri"]]
            ]
        ]
        XCTAssertTrue(mapper.events(forUpdate: params).isEmpty)
    }

    func testThoughtChunkEmitsThinkingDelta() {
        var mapper = ACPUpdateMapper()
        let events = mapper.events(forUpdate: thoughtChunk("considering"))
        XCTAssertEqual(events.count, 1)
        guard case .thinkingDelta(let piece) = events.first else {
            XCTFail("Expected thinking delta")
            return
        }
        XCTAssertEqual(piece, "considering")
        XCTAssertEqual(mapper.accumulatedThinking, "considering")
        XCTAssertEqual(mapper.accumulatedText, "")
    }

    func testThoughtChunkWithContentListAlsoWorks() {
        var mapper = ACPUpdateMapper()
        let params: [String: Any] = [
            "sessionId": "s1",
            "update": [
                "sessionUpdate": "agent_thought_chunk",
                "content": [["type": "text", "text": "list shape"]]
            ]
        ]
        let events = mapper.events(forUpdate: params)
        XCTAssertEqual(events.count, 1)
        guard case .thinkingDelta(let piece) = events.first else {
            XCTFail("Expected thinking delta")
            return
        }
        XCTAssertEqual(piece, "list shape")
    }

    func testInterleavedThoughtAndMessageStreams() {
        var mapper = ACPUpdateMapper()
        var thinking: [String] = []
        var answer: [String] = []
        for params in [thoughtChunk("step one"), messageChunk("Hello"), thoughtChunk("step two")] {
            for event in mapper.events(forUpdate: params) {
                switch event {
                case .delta(let piece): answer.append(piece)
                case .thinkingDelta(let piece): thinking.append(piece)
                default: XCTFail("Unexpected event \(event)")
                }
            }
        }
        XCTAssertEqual(thinking, ["step one", "step two"])
        XCTAssertEqual(answer, ["Hello"])
        XCTAssertEqual(mapper.accumulatedThinking, "step onestep two")
        XCTAssertEqual(mapper.accumulatedText, "Hello")
    }

    func testFinishedEventDoesNotSwallowThinkingAccumulatedByStore() {
        // The mapper hands thinking out only as deltas; the store owns its
        // copy. Terminal event carries just the answer text.
        var mapper = ACPUpdateMapper()
        _ = mapper.events(forUpdate: thoughtChunk("reasoning"))
        _ = mapper.events(forUpdate: messageChunk("answer"))
        guard case .finished(let fullText) = mapper.terminalEvent(stopReason: "end_turn") else {
            XCTFail("Expected finished event")
            return
        }
        XCTAssertEqual(fullText, "answer")
        XCTAssertEqual(mapper.accumulatedThinking, "reasoning")
    }

    func testNonChunkUpdatesEmitNothing() {
        var mapper = ACPUpdateMapper()
        let plan: [String: Any] = [
            "sessionId": "s1",
            "update": ["sessionUpdate": "plan", "entries": []]
        ]
        XCTAssertTrue(mapper.events(forUpdate: plan).isEmpty)
        XCTAssertTrue(mapper.events(forUpdate: nil).isEmpty)
    }

    func testCancelledStopReasonMapsToCancelledEvent() {
        var mapper = ACPUpdateMapper()
        _ = mapper.events(forUpdate: messageChunk("partial"))
        guard case .cancelled = mapper.terminalEvent(stopReason: "cancelled") else {
            XCTFail("Expected cancelled event")
            return
        }
    }
}

// MARK: - In-memory transport tests

/// Records outgoing lines so tests can script incoming ones.
final class FakeACPTransport: ACPTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var messageHandler: (@Sendable (ACPWireMessage) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private(set) var sentLines: [String] = []

    func start(
        onMessage: @escaping @Sendable (ACPWireMessage) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws {
        lock.lock()
        messageHandler = onMessage
        closeHandler = onClose
        lock.unlock()
    }

    func send(_ line: String) async throws {
        lock.lock()
        sentLines.append(line)
        lock.unlock()
    }

    func stop() async {}

    /// Delivers a raw JSON-RPC line as if the agent wrote it.
    func deliver(_ line: String) {
        if let message = ACPJSONRPC.decodeLine(line) {
            lock.lock()
            let handler = messageHandler
            lock.unlock()
            handler?(message)
        }
    }

    func deliverClose() {
        lock.lock()
        let handler = closeHandler
        lock.unlock()
        handler?()
    }

    var sentMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentLines.compactMap { ACPJSONRPC.decodeLine($0) }.compactMap { message in
            if case .request(_, let method, _) = message { return method }
            if case .notification(let method, _) = message { return method }
            return nil
        }
    }
}

final class ACPAgentClientTests: XCTestCase {

    private func makeClient(transport: FakeACPTransport) -> ACPAgentClient {
        ACPAgentClient(
            configuration: ACPAgentConfiguration(
                command: "/usr/local/bin/fake-agent",
                workingDirectory: "/tmp"
            ),
            transportFactory: { _ in transport }
        )
    }

    func testNameIsCommandBasename() {
        let client = ACPAgentClient(
            configuration: ACPAgentConfiguration(command: "/opt/homebrew/bin/gemini")
        )
        XCTAssertEqual(client.name, "gemini")
    }

    func testConfigurationEquatable() {
        let a = ACPAgentConfiguration(command: "/bin/agent", arguments: ["--acp"])
        let b = ACPAgentConfiguration(command: "/bin/agent", arguments: ["--acp"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ACPAgentConfiguration(command: "/bin/other"))
    }

    func testScriptedTurnEmitsDeltasThenFinished() async {
        let transport = FakeACPTransport()
        let client = makeClient(transport: transport)

        var events: [CompanionEvent] = []
        let stream = await client.stream(messages: [ChatMessage(role: .user, content: "hi")], onToolCall: nil)

        let collector = Task {
            for try await event in stream {
                events.append(event)
            }
        }

        // Give the client time to run initialize + session/new + session/prompt.
        try? await Task.sleep(nanoseconds: 200_000_000)

        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1"}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#)

        // Wait for session/prompt to be sent before scripting its updates.
        var promptSent = false
        for _ in 0..<50 where !promptSent {
            promptSent = transport.sentMethods.contains("session/prompt")
            if !promptSent {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTAssertTrue(promptSent, "session/prompt was never sent")

        transport.deliver(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":[{"type":"text","text":"Hel"}]}}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":[{"type":"text","text":"lo"}]}}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#)

        try? await collector.value

        guard case .delta("Hel")? = events.first else {
            XCTFail("Expected first event delta Hel, got \(events)")
            return
        }
        XCTAssertEqual(events.count, 3)
        guard case .finished(let fullText) = events.last else {
            XCTFail("Expected finished terminal, got \(events)")
            return
        }
        XCTAssertEqual(fullText, "Hello")
    }

    func testPermissionRequestIsPolitelyDeclined() async {
        let transport = FakeACPTransport()
        let client = makeClient(transport: transport)

        let stream = await client.stream(messages: [ChatMessage(role: .user, content: "hi")], onToolCall: nil)
        let collector = Task {
            for try await _ in stream {}
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1"}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"s1","options":[{"optionId":"opt-reject","kind":"reject_once"}],"toolCall":{"toolCallId":"t1","title":"run","kind":"execute","status":"pending","content":[]}}}"#)

        try? await Task.sleep(nanoseconds: 200_000_000)

        let responses = transport.sentLines.compactMap { ACPJSONRPC.decodeLine($0) }.compactMap { message -> ACPRequestID? in
            if case .response(let id, let result) = message {
                let outcome = result?["outcome"] as? [String: Any]
                XCTAssertEqual(outcome?["outcome"] as? String, "selected")
                XCTAssertEqual(outcome?["optionId"] as? String, "opt-reject")
                return id
            }
            return nil
        }
        XCTAssertEqual(responses, [.string("perm-1")])

        transport.deliver(#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#)
        try? await collector.value
    }

    func testProcessExitMidTurnFails() async {
        let transport = FakeACPTransport()
        let client = makeClient(transport: transport)

        let stream = await client.stream(messages: [ChatMessage(role: .user, content: "hi")], onToolCall: nil)
        let collector = Task {
            var events: [CompanionEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1"}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#)
        try? await Task.sleep(nanoseconds: 100_000_000)
        transport.deliverClose()

        let events = (try? await collector.value) ?? []
        guard case .failed = events.last else {
            XCTFail("Expected failed terminal on process exit, got \(events)")
            return
        }
    }
}
