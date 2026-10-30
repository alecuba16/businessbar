import Foundation
@testable import BusinessBarCore

@MainActor
enum CoreNetworkScenarios {
    static func run(_ context: CoverageContext) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreNetworkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let previous = CoreNetworkURLProtocol.handler
        defer {
            CoreNetworkURLProtocol.handler = previous
            session.invalidateAndCancel()
        }
        try codecs(context)
        try measuredPureGaps(context)
        try await search(context, session: session)
        try await streaming(context, session: session)
        try await acp(context)
    }

    private static func codecs(_ c: CoverageContext) throws {
        let response = try ACPJSONRPC.encodePermissionRejection(id: .string("permission"), params: ["options": [["kind": "reject_once", "optionId": "reject"]]])
        guard case .response(.string("permission"), let result) = ACPJSONRPC.decodeLine(response) else { throw CoverageContext.Failure(description: "Permission response codec") }
        try c.equal((result?["outcome"] as? [String: Any])?["optionId"] as? String, "reject", "ACP reject option selected")
        let fallback = try ACPJSONRPC.encodePermissionRejection(id: .int(1), params: nil)
        guard case .response(_, let result) = ACPJSONRPC.decodeLine(fallback) else { throw CoverageContext.Failure(description: "Permission fallback codec") }
        try c.equal((result?["outcome"] as? [String: Any])?["outcome"] as? String, "cancelled", "ACP permission fallback cancelled")
        let notification = try ACPJSONRPC.encodeNotification(method: "session/cancel", params: ["sessionId": "s"])
        guard case .notification("session/cancel", _) = ACPJSONRPC.decodeLine(notification) else { throw CoverageContext.Failure(description: "Notification codec") }
        let error = try ACPJSONRPC.encodeErrorResponse(id: .int(3), code: -32601, message: "unsupported")
        guard case .errorResponse(.int(3), -32601, "unsupported") = ACPJSONRPC.decodeLine(error) else { throw CoverageContext.Failure(description: "Error codec") }
        var mapper = ACPUpdateMapper()
        try c.expect(mapper.events(forUpdate: nil).isEmpty, "Missing ACP update ignored")
        try c.expect(mapper.events(forUpdate: ["update": ["sessionUpdate": "plan"]]).isEmpty, "Non-chunk update ignored")
        let mapped = mapper.events(forUpdate: ["update": ["sessionUpdate": "agent_message_chunk", "content": [["type": "image"], ["type": "resource_link", "title": "Docs", "uri": "https://example.invalid"], ["type": "resource_link"], ["type": "text", "text": "text"]]]])
        try c.equal(mapped.map(label), ["text:[Docs](https://example.invalid)", "text:text"], "ACP text and resource mapping")
        try c.equal(label(mapper.terminalEvent(stopReason: "cancelled")), "cancelled", "ACP cancellation mapping")
        try c.expect(RemoteModelCatalog.parse(data: Data("[]".utf8)) == nil, "Catalog invalid root")
        try c.equal(ScrapedSearchProvider.unwrapDDGRedirect("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.invalid&x=1"), "https://example.invalid", "DDG redirect decoding")
        try c.expect(ScrapedSearchProvider.unwrapDDGRedirect("/relative") == nil, "DDG relative link rejected")
        let html = "<a class=\"result__a\" href=\"https://example.invalid\"><b>Title</b></a><a class=\"result__snippet\">Snippet</a>"
        try c.equal(ScrapedSearchProvider.parseDuckDuckGo(html: html)?.first?.title, "Title", "DDG HTML title")
        try c.equal(ScrapedSearchProvider.parseDuckDuckGo(html: html)?.first?.snippet, "Snippet", "DDG HTML snippet")
        try c.expect(ScrapedSearchProvider.parseRSS(data: Data("<item><title>missing link</title></item>".utf8)) == nil, "RSS missing links dropped")
        let history = [ChatMessage(role: .user, content: "old"), ChatMessage(role: .user, content: "Tool 'a' returned:\nlarge\nsecond\nthird"), ChatMessage(role: .user, content: "middle"), ChatMessage(role: .user, content: "new")]
        let folded = OpenAICompatClient.truncateOldToolOutputs(history)
        try c.expect(folded[1].content != history[1].content, "Old tool output folded")
        try c.equal(folded[0], history[0], "User prompt preserved")
        try c.equal(OpenAICompatClient.requestMessage(ChatMessage(role: .assistant, content: "plain"))["content"] as? String, "plain", "Plain request compact shape")
    }

    private static func measuredPureGaps(_ c: CoverageContext) throws {
        try c.equal(EffortVocabulary.knownModelEffortOptions("provider/GPT-5-mini"), ["minimal", "low", "medium", "high"], "GPT-5 vocabulary")
        try c.equal(EffortVocabulary.knownModelEffortOptions("unknown"), [], "Unknown model has no published vocabulary")
        try c.equal(EffortVocabulary.parseList(" low, medium low\nHIGH,,high "), ["low", "medium", "HIGH", "high"], "Effort editor deduplicates preserving case")
        try c.equal(EffortVocabulary.defaultEffort(in: []), nil, "Empty effort vocabulary")
        try c.equal(EffortVocabulary.defaultEffort(in: ["low", "medium", "high"]), "medium", "Preferred medium effort")
        try c.equal(EffortVocabulary.defaultEffort(in: ["a", "b", "c"]), "b", "Middle effort fallback")
        let capability = MLXReasoningCapability(supported: true, shape: .effortLevels, effortOptions: ["low", "medium", "high"])
        try c.equal(EffortVocabulary.resolve(pinnedEffortOptions: [], mlxModelID: "fixture", mlxCapability: capability, modelID: "gpt-5"), capability.effortOptions, "Discovered vocabulary beats model pattern")
        let http = HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let nonHTTP = URLResponse(url: URL(string: "https://fixture.invalid")!, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
        for response in [http as URLResponse, nonHTTP] {
            for body in ["{}", "[]", "not JSON"] {
                try c.expectThrows("Generic search malformed response") { _ = try SearchProviderSupport.decodedItems(from: Data(body.utf8), response: response) }
                try c.expectThrows("Custom search malformed response") { _ = try CustomSearchProvider.decodeItems(from: Data(body.utf8), response: response) }
                try c.expectThrows("GitHub search malformed response") { _ = try GitHubSearchProvider.decodeItems(from: Data(body.utf8), response: response) }
            }
        }
        let variants = try CustomSearchProvider.decodeItems(from: Data(#"{"data":[{"title":"description","link":"https://example.invalid/d","description":"detail"},{"title":"empty","url":"https://example.invalid/e"}]}"#.utf8), response: http)
        try c.equal(variants.map(\.snippet), ["detail", ""], "Custom alternative envelope and snippet fallbacks")
        for error in [SearchProviderError.notConfigured, .http(403), .decoding("broken"), .transport("offline")] {
            try c.expect(error.errorDescription?.isEmpty == false, "Search failures have user descriptions")
        }
    }

    private static func search(_ c: CoverageContext, session: URLSession) async throws {
        CoreNetworkURLProtocol.handler = { request in
            let host = request.url!.host!
            if host == "api.github.com" {
                return (200, #"{"items":[{"repository":{"full_name":"org/repo"},"path":"a.swift","html_url":"https://example.invalid/a","text_matches":[{"fragment":"let a = 1"}]},{}]}"#)
            }
            if host == "html.duckduckgo.com" { return (202, "anomaly challenge") }
            if host == "www.bing.com" {
                return (200, "<rss><item><title>A &amp; B</title><link>https://example.invalid/a</link><description>&lt;b&gt;News&lt;/b&gt;</description></item></rss>")
            }
            if request.url!.path.hasSuffix("/models") {
                return (200, #"{"data":[{"id":"vendor/model","supported_parameters":["reasoning_effort"]},{"id":"plain"},{"id":""},{}]}"#)
            }
            return (200, #"{"results":[{"title":"Result","url":"https://example.invalid","description":"<b>match</b>","content":"body"},{}]}"#)
        }
        let brave = try await BraveSearchProvider(apiKey: "fixture", session: session).search(query: "swift", maxResults: 99)
        try c.equal(brave.first?.snippet, "match", "Brave strips markup")
        let tavily = try await TavilySearchProvider(apiKey: "fixture", session: session).search(query: "swift", maxResults: 0)
        try c.equal(tavily.first?.snippet, "body", "Tavily content mapping")
        let github = try await GitHubSearchProvider(token: "fixture", session: session).search(query: "symbol repo:org/repo", maxResults: 4)
        try c.equal(github.first?.title, "org/repo/a.swift", "GitHub repository path")
        try c.equal(github.first?.snippet, "let a = 1", "GitHub text fragment")
        let custom = CustomSearchProvider(endpoint: URL(string: "https://fixture.invalid/search")!, headers: [(name: "X-Test", value: "fixture")], session: session)
        let legacyHeader = CustomSearchProvider(endpoint: URL(string: "https://fixture.invalid/search")!, headerName: "X-Legacy", headerValue: "yes", session: session)
        let legacyEmpty = CustomSearchProvider(endpoint: URL(string: "https://fixture.invalid/search")!, headerName: "", headerValue: nil, session: session)
        let legacyResults = try await legacyHeader.search(query: "q", maxResults: 1)
        let emptyHeaderResults = try await legacyEmpty.search(query: "q", maxResults: 1)
        try c.equal(legacyResults, emptyHeaderResults, "Legacy custom header initializers")
        let results = try await custom.search(query: "q", maxResults: 2)
        try c.equal(results.count, 1, "Custom drops invalid rows")
        let template = CustomSearchProvider(endpoint: URL(string: "https://fixture.invalid/search?q={query}&n={count}")!, session: session)
        let templated = try await template.search(query: "two words", maxResults: 3)
        try c.equal(templated, results, "Template GET uses common decoder")
        let scraped = try await ScrapedSearchProvider(engine: .duckduckgo, session: session).search(query: "swift", maxResults: 1)
        try c.equal(scraped.first?.title, "A & B", "Challenge falls back to RSS")
        try c.equal(scraped.first?.snippet, "News", "RSS escaped markup")
        CoreNetworkURLProtocol.handler = { request in
            if request.url?.host == "html.duckduckgo.com" {
                return (200, "<a class=\"result__a\" href=\"https://example.invalid\">Direct DDG</a>")
            }
            return (200, "<rss><item><title>Direct Google</title><link>https://example.invalid/news</link></item></rss>")
        }
        let ddg = try await ScrapedSearchProvider(engine: .duckduckgo, session: session).search(query: "q", maxResults: 1)
        try c.equal(ddg.first?.title, "Direct DDG", "DDG primary success without fallback")
        let news = try await ScrapedSearchProvider(engine: .googleNews, session: session).search(query: "q", maxResults: 1)
        try c.equal(news.first?.title, "Direct Google", "Google News primary success")
        CoreNetworkURLProtocol.handler = { _ in (200, #"{"data":[{"id":"vendor/model","supported_parameters":["reasoning_effort"]},{"id":"plain"},{"id":""},{}]}"#) }
        let models = try await RemoteModelCatalog.fetch(baseURL: "https://fixture.invalid/v1///", apiKey: "fixture", headers: [(name: "X-Test", value: "yes")], session: session)
        try c.equal(models.count, 2, "Catalog drops invalid model identifiers")
        try c.expect(models[0].supportsReasoning, "Catalog reasoning metadata")
        try c.equal(models[0].chatModel(effort: "high").name, "model", "Catalog friendly model name")
        for provider in [BraveSearchProvider(apiKey: "", session: session) as any SearchProvider, TavilySearchProvider(apiKey: "", session: session), GitHubSearchProvider(token: "", session: session)] {
            try await c.expectThrowsAsync("Missing credentials rejected") { _ = try await provider.search(query: "q", maxResults: 1) }
        }
        for status in [403, 500] {
            CoreNetworkURLProtocol.handler = { _ in (status, "denied") }
            for provider in [custom as any SearchProvider, BraveSearchProvider(apiKey: "x", session: session), TavilySearchProvider(apiKey: "x", session: session), GitHubSearchProvider(token: "x", session: session), ScrapedSearchProvider(engine: .googleNews, session: session)] {
                try await c.expectThrowsAsync("HTTP errors rejected") { _ = try await provider.search(query: "q", maxResults: 1) }
            }
            try await c.expectThrowsAsync("Catalog HTTP error rejected") { _ = try await RemoteModelCatalog.fetch(baseURL: "https://fixture.invalid", apiKey: "", session: session) }
        }
        CoreNetworkURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        for provider in [custom as any SearchProvider, BraveSearchProvider(apiKey: "x", session: session), TavilySearchProvider(apiKey: "x", session: session), GitHubSearchProvider(token: "x", session: session)] {
            do {
                _ = try await provider.search(query: "q", maxResults: 1)
                try c.expect(false, "Transport failure must throw")
            } catch let error as SearchProviderError {
                guard case .transport = error else { throw CoverageContext.Failure(description: "Transport error incorrectly mapped: \(error)") }
                try c.expect(error.errorDescription?.isEmpty == false, "Transport failure description")
            }
        }
        CoreNetworkURLProtocol.handler = { _ in (200, "not JSON or RSS") }
        try await c.expectThrowsAsync("Malformed custom response rejected") { _ = try await custom.search(query: "q", maxResults: 1) }
        try await c.expectThrowsAsync("All scrape fallbacks exhausted") { _ = try await ScrapedSearchProvider(engine: .bing, session: session).search(query: "q", maxResults: 1) }
        try c.equal(SearchProviderSupport.clampedResultCount(-1), 1, "Minimum search count")
        try c.equal(SearchProviderSupport.clampedResultCount(100), 10, "Maximum search count")
        try c.expect(SearchToolCatalog.toolOutput(from: results).contains("Result"), "Search tool JSON output")
        try c.equal(SearchToolCatalog.webSearchToolSchema()["type"] as? String, "function", "Web tool schema")
        try c.equal(SearchToolCatalog.githubSearchToolSchema()["type"] as? String, "function", "GitHub tool schema")
    }

    private static func collect(_ client: OpenAICompatClient) async throws -> [String] {
        var result: [String] = []
        for try await event in await client.stream(messages: [ChatMessage(role: .user, content: "hello", images: ["data:image/png;base64,AA=="])]) {
            result.append(label(event))
        }
        return result
    }

    private static func label(_ event: CompanionEvent) -> String {
        switch event {
        case .delta(let text): return "text:\(text)"
        case .thinkingDelta(let text): return "thinking:\(text)"
        case .finished(let text): return "finished:\(text)"
        case .failed(let text): return "failed:\(text)"
        case .cancelled: return "cancelled"
        case .toolCallRequested(let name, let arguments): return "tool:\(name):\(arguments)"
        }
    }

    private static func streaming(_ c: CoverageContext, session: URLSession) async throws {
        let config = CompanionConfiguration(baseURL: URL(string: "https://fixture.invalid/v1")!, model: "fixture", apiKey: "key", systemPrompt: "system", reasoning: true, reasoningEffort: "high", extraHeaders: ["X-Test": "yes"])
        CoreNetworkURLProtocol.handler = { request in
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == "Bearer key",
                  request.value(forHTTPHeaderField: "X-Test") == "yes",
                  request.url?.path == "/v1/chat/completions",
                  let data = try CoreNetworkURLProtocol.body(request),
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["model"] as? String == "fixture",
                  body["reasoning_effort"] as? String == "high",
                  let messages = body["messages"] as? [[String: Any]], messages.count == 2,
                  messages[0]["role"] as? String == "system",
                  let parts = messages[1]["content"] as? [[String: Any]], parts.count == 2,
                  (parts[1]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,AA=="
            else { throw URLError(.badServerResponse) }
            return (200, "ignore\ndata: malformed\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hel\",\"reasoning\":\"why\"}}]}\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\",\"reasoning_content\":\"now\"}}]}\ndata: [DONE]\n")
        }
        let events = try await collect(OpenAICompatClient(configuration: config, session: session))
        try c.equal(events, ["text:Hel", "thinking:why", "text:lo", "thinking:now", "finished:Hello"], "Fragmented SSE text and reasoning")
        CoreNetworkURLProtocol.handler = { _ in (429, "quota exhausted") }
        let failed = try await collect(OpenAICompatClient(configuration: config, session: session))
        try c.expect(failed.count == 1 && failed[0].contains("429") && failed[0].contains("quota exhausted"), "HTTP produces one failure with server detail")
        CoreNetworkURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let cancelled = try await collect(OpenAICompatClient(configuration: config, session: session))
        try c.equal(cancelled, ["cancelled"], "Transport cancellation")
        let toolBody = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"search\",\"arguments\":\"{\"}}]}}]}\ndata: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n"
        CoreNetworkURLProtocol.handler = { _ in (200, toolBody) }
        let unavailable = try await collect(OpenAICompatClient(configuration: config, session: session))
        try c.expect(unavailable.count == 1 && unavailable[0].contains("no tool handler"), "Missing tool handler fails")
        let limited = try await collect(OpenAICompatClient(configuration: config, toolHandler: { _, _ in "result" }, maxToolRounds: 1, session: session))
        try c.expect(limited.count == 2 && limited[0] == "tool:search:{}" && limited[1].contains("round limit"), "Tool round limit terminates")
        let shape = OpenAICompatClient.requestMessage(ChatMessage(role: .user, content: "look", images: ["data:image/png;base64,AA=="]))
        try c.equal((shape["content"] as? [[String: Any]])?.count, 2, "Image request content parts")
        let advertised = SearchToolCatalog.webSearchToolSchema()
        CoreNetworkURLProtocol.handler = { request in
            guard let data = try CoreNetworkURLProtocol.body(request),
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (body["tools"] as? [[String: Any]])?.count == 1
            else { throw URLError(.badServerResponse) }
            return (200, "data: [DONE]\n")
        }
        let advertisedEvents = try await collect(OpenAICompatClient(configuration: config, tools: [advertised], session: session))
        try c.equal(advertisedEvents, ["finished:"], "Advertised tool schema is sent")
        let invalidEvents = try await collect(OpenAICompatClient(configuration: config, tools: [["invalid": Date()]], session: session))
        try c.equal(invalidEvents, ["failed:Could not encode request body."], "Non-JSON tool payload fails before request")
        var local = config
        local.isLocalMLX = true
        local.mlxReasoning = MLXReasoningCapability(supported: true, shape: .effortLevels, effortOptions: ["low", "medium", "high"])
        CoreNetworkURLProtocol.handler = { request in
            guard let data = try CoreNetworkURLProtocol.body(request),
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["reasoning_effort"] == nil,
                  (body["chat_template_kwargs"] as? [String: String])?["reasoning_effort"] == "high"
            else { throw URLError(.badServerResponse) }
            return (200, "data: [DONE]\n")
        }
        let localEvents = try await collect(OpenAICompatClient(configuration: local, session: session))
        try c.equal(localEvents, ["finished:"], "Local template kwargs replace remote effort field")
        CoreNetworkURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let timeout = try await collect(OpenAICompatClient(configuration: config, session: session))
        try c.expect(timeout.count == 1 && timeout[0].hasPrefix("failed:Request failed:"), "Transport failure emits one failure")
        CoreNetworkURLProtocol.handler = { _ in (0, "not HTTP") }
        let nonHTTP = try await collect(OpenAICompatClient(configuration: config, session: session))
        try c.equal(nonHTTP, ["failed:Unexpected non-HTTP response."], "Non-HTTP stream rejected")
    }

    private static func acp(_ c: CoverageContext) async throws {
        for malformed in ["", "[]", "not json", "{}"] { try c.expect(ACPJSONRPC.decodeLine(malformed) == nil, "Malformed ACP ignored") }
        let encoded = try ACPJSONRPC.encodeInitializeRequest(id: .int(7))
        guard case .request(.int(7), "initialize", _) = ACPJSONRPC.decodeLine(encoded) else { throw CoverageContext.Failure(description: "ACP initialize roundtrip") }
        let transport = CoreNetworkACPTransport()
        let client = ACPAgentClient(configuration: ACPAgentConfiguration(command: "/never-launched/fixture", workingDirectory: "/", systemPrompt: "system"), transportFactory: { _ in transport })
        for _ in 0..<2 {
            var events: [String] = []
            for try await event in await client.stream(messages: [ChatMessage(role: .user, content: "hello")], onToolCall: nil) { events.append(label(event)) }
            try c.equal(events, ["thinking:think", "text:answer", "finished:answer"], "Fake ACP turn")
        }
        try c.equal(transport.methods.filter { $0 == "initialize" }.count, 1, "ACP connection reused")
        try c.equal(transport.methods.filter { $0 == "session/new" }.count, 1, "ACP session reused")
        try c.expect(client.recentStderr.isEmpty, "Fake transport has no process stderr")
        await client.shutdown()
        try c.equal(transport.stops, 1, "Fake transport shutdown")
        for (mode, expected) in [(CoreNetworkACPTransport.Mode.startError, "failed:"), (.initializeError, "failed:"), (.missingSession, "failed:"), (.initializeMissingResult, "failed:"), (.promptError, "failed:prompt rejected"), (.cancelled, "cancelled"), (.closed, "failed:Agent process exited")] {
            let failingTransport = CoreNetworkACPTransport(mode: mode)
            let failingClient = ACPAgentClient(configuration: ACPAgentConfiguration(command: "/never-launched/fixture", workingDirectory: "/"), transportFactory: { _ in failingTransport })
            var failureEvents: [String] = []
            for try await event in await failingClient.stream(messages: [], onToolCall: nil) { failureEvents.append(label(event)) }
            try c.expect(failureEvents.last?.hasPrefix(expected) == true, "ACP \(mode) outcome: \(failureEvents)")
            await failingClient.shutdown()
        }
        let requestsTransport = CoreNetworkACPTransport(mode: .serverRequests)
        let requestsClient = ACPAgentClient(configuration: ACPAgentConfiguration(command: "/never-launched/fixture", workingDirectory: "/"), transportFactory: { _ in requestsTransport })
        for try await _ in await requestsClient.stream(messages: [], onToolCall: nil) {}
        try await wait(c, "ACP server request replies") { requestsTransport.wireLines.filter { line in
            guard let message = ACPJSONRPC.decodeLine(line) else { return false }
            switch message { case .response, .errorResponse: return true; default: return false }
        }.count == 2 }
        let replies = requestsTransport.wireLines.compactMap(ACPJSONRPC.decodeLine)
        try c.expect(replies.contains { message in
            guard case .response(.string("permission"), let result) = message else { return false }
            return (result?["outcome"] as? [String: Any])?["optionId"] as? String == "deny"
        }, "ACP permission request selects rejection")
        try c.expect(replies.contains { message in
            guard case .errorResponse(.string("unsupported"), -32601, _) = message else { return false }
            return true
        }, "ACP unknown server method rejected")
        await requestsClient.shutdown()
        let heldTransport = CoreNetworkACPTransport(mode: .heldPrompt)
        let heldClient = ACPAgentClient(configuration: ACPAgentConfiguration(command: "/never-launched/fixture", workingDirectory: "/"), transportFactory: { _ in heldTransport })
        let heldStream = await heldClient.stream(messages: [], onToolCall: nil)
        let consumer = Task { for try await _ in heldStream {} }
        try await wait(c, "ACP prompt active before cancellation") { heldTransport.methods.contains("session/prompt") }
        try await Task.sleep(nanoseconds: 10_000_000)
        consumer.cancel()
        _ = try await consumer.value
        try await wait(c, "ACP cancellation notification") { heldTransport.methods.contains("session/cancel") }
        await heldClient.shutdown()
        let shutdownTransport = CoreNetworkACPTransport(mode: .heldPrompt)
        let shutdownClient = ACPAgentClient(configuration: ACPAgentConfiguration(command: "/never-launched/fixture", workingDirectory: "/"), transportFactory: { _ in shutdownTransport })
        let shutdownStream = await shutdownClient.stream(messages: [], onToolCall: nil)
        let shutdownConsumer = Task { () -> [String] in
            var events: [String] = []
            for try await event in shutdownStream { events.append(label(event)) }
            return events
        }
        try await wait(c, "ACP prompt active before shutdown") { shutdownTransport.methods.contains("session/prompt") }
        try await Task.sleep(nanoseconds: 10_000_000)
        await shutdownClient.shutdown()
        let shutdownEvents = try await shutdownConsumer.value
        try c.expect(shutdownTransport.methods.contains("session/cancel"), "Shutdown cancels active ACP prompt")
        try c.expect(shutdownEvents.last?.hasPrefix("failed:") == true, "Stopped transport resolves active prompt")
    }

    private static func wait(_ c: CoverageContext, _ message: String, condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { try c.expect(true, message); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try c.expect(condition(), message)
    }
}

private final class CoreNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    static func body(_ request: URLRequest) throws -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (status, body) = try handler(request)
            let response: URLResponse
            if status == 0 {
                response = URLResponse(url: request.url!, mimeType: "text/plain", expectedContentLength: body.utf8.count, textEncodingName: "utf-8")
            } else {
                response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = Data(body.utf8)
            for offset in stride(from: 0, to: data.count, by: 7) { client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 7, data.count))) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class CoreNetworkACPTransport: ACPTransport, @unchecked Sendable {
    enum Mode { case normal, startError, initializeError, initializeMissingResult, missingSession, promptError, cancelled, closed, serverRequests, heldPrompt }
    private let mode: Mode
    init(mode: Mode = .normal) { self.mode = mode }
    private let lock = NSLock()
    private var close: (@Sendable () -> Void)?
    private var receive: (@Sendable (ACPWireMessage) -> Void)?
    private var sent: [String] = []
    private var lines: [String] = []
    var wireLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    private var stopCount = 0
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return sent }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    func start(onMessage: @escaping @Sendable (ACPWireMessage) -> Void, onClose: @escaping @Sendable () -> Void) async throws {
        if mode == .startError { throw ACPTransportError.notRunning }
        lock.lock()
        receive = onMessage
        close = onClose
        lock.unlock()
    }
    func send(_ line: String) async throws {
        lock.lock()
        lines.append(line)
        lock.unlock()
        guard let message = ACPJSONRPC.decodeLine(line) else { return }
        if case .notification(let method, _) = message {
            lock.lock(); sent.append(method); lock.unlock()
            return
        }
        guard case .request(let id, let method, _) = message else { return }
        lock.lock(); sent.append(method); let receive = self.receive; lock.unlock()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            switch method {
            case "initialize":
                if mode == .initializeError { receive?(.errorResponse(id: id, code: -1, message: "initialize rejected")) }
                else if mode == .initializeMissingResult { receive?(.response(id: id, result: nil)) }
                else { receive?(.response(id: id, result: ["protocolVersion": "1"])) }
            case "session/new": receive?(.response(id: id, result: mode == .missingSession ? [:] : ["sessionId": "fixture"]))
            default:
                if mode == .promptError { receive?(.errorResponse(id: id, code: -1, message: "prompt rejected")); return }
                if mode == .cancelled { receive?(.response(id: id, result: ["stopReason": "cancelled"])); return }
                if mode == .closed { close?(); return }
                if mode == .heldPrompt { return }
                if mode == .serverRequests {
                    receive?(.request(id: .string("permission"), method: "session/request_permission", params: ["options": [["kind": "reject_once", "optionId": "deny"]]]))
                    receive?(.request(id: .string("unsupported"), method: "unknown/method", params: nil))
                    receive?(.notification(method: "unknown/update", params: nil))
                }
                for (kind, text) in [("agent_thought_chunk", "think"), ("agent_message_chunk", "answer")] {
                    receive?(.notification(method: "session/update", params: ["update": ["sessionUpdate": kind, "content": ["type": "text", "text": text]]]))
                }
                receive?(.response(id: id, result: ["stopReason": "end_turn"]))
            }
        }
    }
    func stop() async {
        lock.lock()
        stopCount += 1
        let close = self.close
        lock.unlock()
        if mode == .heldPrompt { close?() }
    }
}
