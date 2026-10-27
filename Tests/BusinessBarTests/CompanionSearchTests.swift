import XCTest
@testable import BusinessBarCore

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CompanionSearchTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        session = nil
        super.tearDown()
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - BraveSearchProvider

    func testBraveParsesResultsAndStripsTags() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.search.brave.com")
            XCTAssertEqual(request.url?.path, "/res/v1/web/search")
            let item: [String: Any] = [
                "title": "Example",
                "url": "https://example.com",
                "description": "The <b>best</b> example page"
            ]
            let body = ["results": [item]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (
                self.httpResponse(status: 200, url: request.url!),
                data
            )
        }
        let provider = BraveSearchProvider(apiKey: "key", session: session)
        let results = try! await provider.search(query: "example", maxResults: 5)
        XCTAssertEqual(results, [
            SearchResultItem(
                title: "Example",
                url: "https://example.com",
                snippet: "The best example page"
            )
        ])
    }

    func testBraveThrowsNotConfiguredWithoutKey() async {
        let provider = BraveSearchProvider(apiKey: "", session: session)
        do {
            _ = try await provider.search(query: "x", maxResults: 5)
            XCTFail("Expected notConfigured")
        } catch let error as SearchProviderError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testBraveMapsUnauthorizedAndRateLimitToHTTP() async {
        for code in [401, 429] {
            StubURLProtocol.handler = { request in
                (self.httpResponse(status: code, url: request.url!), Data())
            }
            let provider = BraveSearchProvider(apiKey: "key", session: session)
            do {
                _ = try await provider.search(query: "x", maxResults: 5)
                XCTFail("Expected http(\(code))")
            } catch let error as SearchProviderError {
                XCTAssertEqual(error, .http(code))
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testBraveMapsGarbageBodyToDecoding() async {
        StubURLProtocol.handler = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("not json".utf8))
        }
        let provider = BraveSearchProvider(apiKey: "key", session: session)
        do {
            _ = try await provider.search(query: "x", maxResults: 5)
            XCTFail("Expected decoding error")
        } catch let error as SearchProviderError {
            guard case .decoding = error else {
                XCTFail("Expected .decoding, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - TavilySearchProvider

    func testTavilyParsesResults() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.tavily.com")
            XCTAssertEqual(request.url?.path, "/search")
            XCTAssertEqual(request.httpMethod, "POST")
            let item: [String: Any] = [
                "title": "Tavily Example",
                "url": "https://tavily.example.com",
                "content": "Some content"
            ]
            let body = ["results": [item]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (self.httpResponse(status: 200, url: request.url!), data)
        }
        let provider = TavilySearchProvider(apiKey: "key", session: session)
        let results = try! await provider.search(query: "example", maxResults: 3)
        XCTAssertEqual(results, [
            SearchResultItem(
                title: "Tavily Example",
                url: "https://tavily.example.com",
                snippet: "Some content"
            )
        ])
    }

    func testTavilyMapsHTTPError() async {
        StubURLProtocol.handler = { request in
            (self.httpResponse(status: 429, url: request.url!), Data())
        }
        let provider = TavilySearchProvider(apiKey: "key", session: session)
        do {
            _ = try await provider.search(query: "x", maxResults: 5)
            XCTFail("Expected http(429)")
        } catch let error as SearchProviderError {
            XCTAssertEqual(error, .http(429))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testTavilyDecodingFailure() async {
        StubURLProtocol.handler = { request in
            (self.httpResponse(status: 200, url: request.url!), Data("{\"nope\": 1}".utf8))
        }
        let provider = TavilySearchProvider(apiKey: "key", session: session)
        do {
            _ = try await provider.search(query: "x", maxResults: 5)
            XCTFail("Expected decoding error")
        } catch let error as SearchProviderError {
            guard case .decoding = error else {
                XCTFail("Expected .decoding, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - CustomSearchProvider

    func testCustomParsesDataArrayWithAlternativeKeys() async {
        StubURLProtocol.handler = { request in
            let item: [String: Any] = [
                "title": "Custom",
                "link": "https://custom.example.com",
                "content": "flexible content"
            ]
            let body = ["data": [item]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (self.httpResponse(status: 200, url: request.url!), data)
        }
        let provider = CustomSearchProvider(
            endpoint: URL(string: "https://custom.example.com/search")!,
            headerName: "Authorization",
            headerValue: "Bearer tok",
            session: session
        )
        let results = try! await provider.search(query: "x", maxResults: 5)
        XCTAssertEqual(results, [
            SearchResultItem(
                title: "Custom",
                url: "https://custom.example.com",
                snippet: "flexible content"
            )
        ])
    }

    // MARK: - SearchToolCatalog

    func testToolOutputProducesValidJSONWithResults() throws {
        let results = [
            SearchResultItem(title: "A", url: "https://a.com", snippet: "sa"),
            SearchResultItem(title: "B", url: "https://b.com", snippet: "sb")
        ]
        let output = SearchToolCatalog.toolOutput(from: results)
        let data = try XCTUnwrap(Data(output.utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["title"] as? String, "A")
        XCTAssertEqual(items[0]["url"] as? String, "https://a.com")
        XCTAssertEqual(items[0]["snippet"] as? String, "sa")
    }

    func testWebSearchToolSchemaShape() {
        let schema = SearchToolCatalog.webSearchToolSchema()
        XCTAssertEqual(schema["type"] as? String, "function")
        let function = schema["function"] as? [String: Any]
        XCTAssertNotNil(function)
        XCTAssertEqual(function?["name"] as? String, "web_search")
        let parameters = function?["parameters"] as? [String: Any]
        XCTAssertEqual(parameters?["type"] as? String, "object")
        XCTAssertEqual(parameters?["required"] as? [String], ["query"])
    }
}
// MARK: - ScrapedSearchProvider

extension CompanionSearchTests {

    func testScrapedEnginesFallbackChain() {
        XCTAssertEqual(
            ScrapedSearchProvider.engines(after: .duckduckgo),
            [.duckduckgo, .bing, .googleNews])
        XCTAssertEqual(
            ScrapedSearchProvider.engines(after: .bing),
            [.bing, .googleNews, .duckduckgo])
        XCTAssertEqual(
            ScrapedSearchProvider.engines(after: .googleNews),
            [.googleNews, .duckduckgo, .bing])
    }

    func testScrapedParsesBingRSS() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "www.bing.com")
            XCTAssertEqual(request.url?.queryItems?.first { $0.name == "format" }?.value, "rss")
            let xml = """
            <rss version="2.0"><channel><item>
            <title>Swift.org</title>
            <link>https://www.swift.org/</link>
            <description>The Swift &lt;b&gt;programming&lt;/b&gt; language</description>
            </item><item>
            <title>Apple Docs</title>
            <link>https://developer.apple.com/swift/</link>
            <description>Apple&amp;#39;s docs</description>
            </item></channel></rss>
            """
            return (
                self.httpResponse(status: 200, url: request.url!),
                Data(xml.utf8)
            )
        }

        let provider = ScrapedSearchProvider(engine: .bing, session: session!)
        let items = try! await provider.search(query: "swift", maxResults: 5)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Swift.org")
        XCTAssertEqual(items[0].url, "https://www.swift.org/")
        XCTAssertEqual(items[0].snippet, "The Swift programming language")
        XCTAssertEqual(items[1].snippet, "Apple's docs")
    }

    func testScrapedFallsBackWhenDDGChallenged() async {
        StubURLProtocol.handler = { request in
            if request.url?.host == "html.duckduckgo.com" {
                return (
                    self.httpResponse(status: 202, url: request.url!),
                    Data("<html><body>anomaly challenge page</body></html>".utf8)
                )
            }
            XCTAssertEqual(request.url?.host, "www.bing.com")
            let xml = "<rss><channel><item><title>Result</title><link>https://r.example</link><description>d</description></item></channel></rss>"
            return (self.httpResponse(status: 200, url: request.url!), Data(xml.utf8))
        }

        let provider = ScrapedSearchProvider(engine: .duckduckgo, session: session!)
        let items = try! await provider.search(query: "q", maxResults: 5)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].url, "https://r.example")
    }

    func testScrapedChallengeDetection() {
        XCTAssertTrue(ScrapedSearchProvider.looksLikeChallenge(
            "<html>anomaly challenge script</html>"))
        XCTAssertFalse(ScrapedSearchProvider.looksLikeChallenge(
            "<a class=\"result__a\" href=\"x\">t</a>"))
        XCTAssertFalse(ScrapedSearchProvider.looksLikeChallenge("<html>plain page</html>"))
    }

    func testScrapedParsesDDGHTML() {
        let html = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=abc">Example <b>Site</b></a>
        <a class="result__snippet" href="https://example.com/a">A great example page</a>
        <a class="result__a" href="https://other.example">Other</a>
        <a class="result__snippet" href="https://other.example">Second snippet</a>
        """
        let items = ScrapedSearchProvider.parseDuckDuckGo(html: html)
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0].url, "https://example.com/a")
        XCTAssertEqual(items?[0].title, "Example Site")
        XCTAssertEqual(items?[0].snippet, "A great example page")
        XCTAssertEqual(items?[1].url, "https://other.example")
    }

    func testScrapedUnwrapRedirectRejectsRelative() {
        XCTAssertNil(ScrapedSearchProvider.unwrapDDGRedirect("/lite/"))
        XCTAssertEqual(
            ScrapedSearchProvider.unwrapDDGRedirect("//duckduckgo.com/l/?uddg=https%3A%2F%2Fx.io%2Fp&amp;k=x"),
            "https://x.io/p")
    }

    func testScrapedGoogleNewsParses() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "news.google.com")
            XCTAssertEqual(request.url?.path, "/rss/search")
            let xml = "<rss><channel><item><title>News &amp; more</title><link>https://news.example/x</link><description>desc</description></item></channel></rss>"
            return (self.httpResponse(status: 200, url: request.url!), Data(xml.utf8))
        }

        let provider = ScrapedSearchProvider(engine: .googleNews, session: session!)
        let items = try! await provider.search(query: "swift", maxResults: 5)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "News & more")
    }

    func testScrapedThrowsWhenAllEnginesFail() async {
        StubURLProtocol.handler = { request in
            (self.httpResponse(status: 403, url: request.url!), Data())
        }

        let provider = ScrapedSearchProvider(engine: .duckduckgo, session: session!)
        do {
            _ = try await provider.search(query: "q", maxResults: 5)
            XCTFail("expected throw")
        } catch {
            guard case SearchProviderError.http(let code) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(code, 403)
        }
    }
}
