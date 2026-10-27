import XCTest
@testable import BusinessBarCore

final class PromptTemplateTests: XCTestCase {

    func testRenderSubstitutesPlaceholder() {
        let template = PromptTemplate(name: "Improve", prompt: "Improve this:\n[placeholder]")
        XCTAssertEqual(
            template.render(with: "hello world"),
            "Improve this:\nhello world"
        )
    }

    func testRenderSubstitutesAllOccurrences() {
        let template = PromptTemplate(name: "T", prompt: "[placeholder] and [placeholder]")
        XCTAssertEqual(
            template.render(with: "X"),
            "X and X"
        )
    }

    func testRenderWithoutPlaceholderAppendsSelection() {
        let template = PromptTemplate(name: "T", prompt: "Summarize this text.")
        XCTAssertEqual(
            template.render(with: "body text"),
            "Summarize this text.\n\nbody text"
        )
    }

    func testRenderWithEmptySelection() {
        let template = PromptTemplate(name: "T", prompt: "Do it: [placeholder]")
        XCTAssertEqual(template.render(with: ""), "Do it: ")
    }

    func testDefaultsAreNonEmpty() {
        XCTAssertFalse(PromptTemplate.defaults.isEmpty)
        for template in PromptTemplate.defaults {
            XCTAssertFalse(template.name.isEmpty)
            XCTAssertFalse(template.prompt.isEmpty)
        }
    }

    func testCodableRoundTrip() throws {
        let original = PromptTemplate.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([PromptTemplate].self, from: data)
        XCTAssertEqual(original, decoded)
    }
}

final class TemplateStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "companion-template-tests-\(UUID().uuidString)")
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first)
    }

    override func tearDown() {
        if let name = suite.dictionaryRepresentation().keys.first {
            suite.removePersistentDomain(forName: name)
        }
        suite = nil
        super.tearDown()
    }

    func testLoadSeedsDefaultsWhenEmpty() {
        let store = TemplateStore(defaults: suite)
        let loaded = store.load()
        XCTAssertEqual(loaded, PromptTemplate.defaults)
        // Seeding persists: a second store sees the same data.
        XCTAssertEqual(TemplateStore(defaults: suite).load(), PromptTemplate.defaults)
    }

    func testSaveAndLoadRoundTrip() {
        let store = TemplateStore(defaults: suite)
        let custom = [PromptTemplate(name: "Custom", prompt: "custom [placeholder]")]
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }

    func testLoadFallsBackToDefaultsAfterEmptySave() {
        let store = TemplateStore(defaults: suite)
        store.save([])
        // An empty array is treated as "nothing stored" and re-seeded.
        XCTAssertEqual(store.load(), PromptTemplate.defaults)
    }
}

final class OpenAICompatClientTests: XCTestCase {

    /// Session wired to StubURLProtocol (defined in CompanionSearchTests)
    /// so requests never leave the process.
    static let stubbedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "companion-client-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suite.suiteName)
        suite = nil
        super.tearDown()
    }

    private func makeClient() -> OpenAICompatClient {
        OpenAICompatClient(
            configuration: CompanionConfiguration(
                baseURL: URL(string: "http://localhost:1/v1")!,
                model: "test-model",
                apiKey: "test-key"
            )
        )
    }

    func testConfigurationDefaults() {
        XCTAssertEqual(CompanionConfiguration.default.model, "gpt-4o-mini")
        XCTAssertEqual(CompanionConfiguration.default.baseURL.absoluteString, "https://api.openai.com/v1")
        XCTAssertTrue(CompanionConfiguration.default.apiKey.isEmpty)
    }

    func testStreamEmitsFailedEventOnConnectionError() async {
        let client = makeClient()
        // Port 1 refuses connections: no server, no network needed.
        var terminal: CompanionEvent?
        do {
            for try await event in client.stream(messages: [
                ChatMessage(role: .user, content: "hi")
            ], onToolCall: nil) {
                switch event {
                case .finished, .failed, .cancelled:
                    terminal = event
                default:
                    break
                }
                if terminal != nil { break }
            }
        } catch {
            XCTFail("Stream should deliver terminal events, not throw: \(error)")
        }
        guard case .failed = terminal else {
            XCTFail("Expected .failed terminal event, got \(String(describing: terminal))")
            return
        }
    }
}
// MARK: - Reasoning and header request shaping

extension OpenAICompatClientTests {

    private func sseOKResponse(url: URL?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "http://localhost")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!
    }

    private func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func testReasoningEffortAndHeadersSentInRequest() async {
        var seenBody: [String: Any]?
        var seenHeaders: [String: String]?
        StubURLProtocol.handler = { request in
            let data = self.bodyData(of: request)
            seenBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            var headers: [String: String] = [:]
            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                headers[name] = value
            }
            seenHeaders = headers
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
            return (self.sseOKResponse(url: request.url), Data(sse.utf8))
        }

        let client = OpenAICompatClient(
            configuration: CompanionConfiguration(
                baseURL: URL(string: "http://localhost:1/v1")!,
                model: "test-model",
                apiKey: "test-key",
                reasoning: true,
                reasoningEffort: "xhigh",
                extraHeaders: ["X-Gateway-Account": "revolut-non-coding"]
            ),
            session: Self.stubbedSession
        )

        var finished = false
        do {
            let stream = client.stream(messages: [ChatMessage(role: .user, content: "hi")], onToolCall: nil)
            for try await event in stream {
                if case .finished = event { finished = true }
            }
        } catch {
            XCTFail("stream threw: \(error)")
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(seenBody?["reasoning_effort"] as? String, "xhigh")
        XCTAssertEqual(seenHeaders?["X-Gateway-Account"], "revolut-non-coding")
        XCTAssertEqual(seenHeaders?["Authorization"], "Bearer test-key")
    }

    func testReasoningOffOmitsEffort() async {
        var seenBody: [String: Any]?
        StubURLProtocol.handler = { request in
            seenBody = try? JSONSerialization.jsonObject(with: self.bodyData(of: request)) as? [String: Any]
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
            return (self.sseOKResponse(url: request.url), Data(sse.utf8))
        }

        let client = OpenAICompatClient(
            configuration: CompanionConfiguration(
                baseURL: URL(string: "http://localhost:1/v1")!,
                model: "test-model",
                apiKey: "test-key",
                reasoning: false,
                reasoningEffort: "high"
            ),
            session: Self.stubbedSession
        )

        do {
            let stream = client.stream(messages: [ChatMessage(role: .user, content: "hi")], onToolCall: nil)
            for try await _ in stream {}
        } catch {
            XCTFail("stream threw: \(error)")
        }

        XCTAssertNil(seenBody?["reasoning_effort"])
    }
}

final class RewriteOutputCaptureTests: XCTestCase {
    func testTaggedReplyDropsCommentary() {
        let reply = "Here's what I fixed:\n<output>The cat sat.</output>\nLet me know if you want more changes."
        XCTAssertEqual(RewriteOutputCapture.capture(from: reply), "The cat sat.")
    }

    func testTaggedReplyUnwrapsCodeFence() {
        let reply = "<output>\n```\nThe cat sat.\n```\n</output>"
        XCTAssertEqual(RewriteOutputCapture.capture(from: reply), "The cat sat.")
    }

    func testInnerFencesSurviveFenceUnwrap() {
        // Fences inside the content do not wrap the whole capture, so
        // they stay untouched.
        let reply = "<output>\n```swift\nlet x = 1\n```\n\nMore text after.\n</output>"
        let captured = RewriteOutputCapture.capture(from: reply)
        XCTAssertTrue(captured.contains("```swift"))
        XCTAssertTrue(captured.hasSuffix("More text after."))
    }

    func testUntaggedReplyStripsLeadingCommentary() {
        let reply = "Sure! Here's the corrected text:\n\nShe doesn't know."
        XCTAssertEqual(RewriteOutputCapture.capture(from: reply), "She doesn't know.")
    }

    func testUntaggedReplyWithoutCommentaryStaysIntact() {
        let reply = "She doesn't know."
        XCTAssertEqual(RewriteOutputCapture.capture(from: reply), reply)
    }

    func testSingleLineReplySurvives() {
        // A one-line answer starting with a starter word must not lose its
        // only line.
        XCTAssertEqual(RewriteOutputCapture.capture(from: "Sure, done."), "Sure, done.")
    }

    func testUnclosedTagFallsBackToCommentaryStrip() {
        let reply = "Here's the corrected text:\n<output>She doesn't know."
        XCTAssertEqual(RewriteOutputCapture.capture(from: reply), "<output>She doesn't know.")
    }

    func testEmptyTagsReturnEmptyString() {
        XCTAssertEqual(RewriteOutputCapture.capture(from: "<output></output>"), "")
    }

    func testDefaultTemplatesAskForOutputTags() {
        for template in PromptTemplate.defaults {
            XCTAssertTrue(template.prompt.contains("<output>"), "missing tag: \(template.name)")
            XCTAssertTrue(template.prompt.contains("</output>"), "missing close tag: \(template.name)")
        }
    }
}

final class TemplateAutoReplaceTests: XCTestCase {
    func testStoredTemplatesWithoutFlagDecodeAsManual() throws {
        let json = """
        [{"id":"B69E128A-1E52-4D34-8E29-CD712AA3D782","name":"Rewrite","prompt":"p"}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([PromptTemplate].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertFalse(decoded[0].autoReplace)
    }

    func testAutoReplaceFlagSurvivesRoundTrip() throws {
        let template = PromptTemplate(name: "T", prompt: "p", autoReplace: true)
        let data = try JSONEncoder().encode([template])
        let decoded = try JSONDecoder().decode([PromptTemplate].self, from: data)
        XCTAssertTrue(decoded[0].autoReplace)
    }

    func testContainsOutputTags() {
        XCTAssertTrue(RewriteOutputCapture.containsOutputTags("intro\n<output>text</output>"))
        XCTAssertFalse(RewriteOutputCapture.containsOutputTags("<output>unclosed"))
        XCTAssertFalse(RewriteOutputCapture.containsOutputTags("plain reply"))
        XCTAssertFalse(RewriteOutputCapture.containsOutputTags("</output> before <output>"))
    }
}
