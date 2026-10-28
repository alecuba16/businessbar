import Foundation

// MARK: - ScrapedSearchEngine

/// Which well-known site to scrape. No API keys: these read the same
/// pages a browser gets.
public enum ScrapedSearchEngine: String, CaseIterable, Sendable {
    case duckduckgo
    case bing
    case googleNews

    public var displayName: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .googleNews: return "Google News"
        }
    }
}

// MARK: - ScrapedSearchProvider

/// Scrapes a public search page instead of calling a billed API.
/// Each engine falls back to the next when blocked or empty, so one
/// site's anti-bot wall does not fail the whole search.
public final class ScrapedSearchProvider: SearchProvider, @unchecked Sendable {
    public let name: String

    private let primary: ScrapedSearchEngine
    private let session: URLSession

    public init(engine: ScrapedSearchEngine, session: URLSession = .shared) {
        self.primary = engine
        self.session = session
        self.name = engine.displayName
    }

    public func search(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        let wanted = SearchProviderSupport.clampedResultCount(maxResults)
        let chain = ScrapedSearchProvider.engines(after: primary)

        var lastError: Error = SearchProviderError.decoding("no engine produced results")
        for engine in chain {
            do {
                let results = try await run(engine: engine, query: query, maxResults: wanted)
                if !results.isEmpty {
                    return Array(results.prefix(wanted))
                }
                // Empty page: keep trying the next engine before giving up.
                lastError = SearchProviderError.decoding("\(engine.displayName) returned no results")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Primary first, then the other engines in a fixed order.
    public static func engines(after primary: ScrapedSearchEngine) -> [ScrapedSearchEngine] {
        let rotation = ScrapedSearchEngine.allCases
        guard let start = rotation.firstIndex(of: primary) else { return rotation }
        return Array(rotation[start...]) + Array(rotation[..<start])
    }

    private func run(engine: ScrapedSearchEngine, query: String, maxResults: Int) async throws -> [SearchResultItem] {
        switch engine {
        case .duckduckgo: return try await duckduckgo(query: query, maxResults: maxResults)
        case .bing: return try await bingRSS(query: query, maxResults: maxResults)
        case .googleNews: return try await googleNewsRSS(query: query, maxResults: maxResults)
        }
    }

    // MARK: Request plumbing

    /// All engines rate-limit automated-looking hits, so requests stay
    /// conservative: desktop Safari headers, no cookies, short timeout.
    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SearchProviderError.transport("unexpected non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SearchProviderError.http(http.statusCode)
        }
        return data
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private static func makeRequest(url: URL, timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = timeout
        return request
    }

    // MARK: DuckDuckGo HTML

    /// DuckDuckGo's html endpoint serves a plain results page. When the
    /// anomaly challenge appears (HTTP 202 with the challenge markup) it
    /// throws and the chain falls through to Bing.
    private func duckduckgo(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kl", value: "wt-wt")
        ]
        let request = Self.makeRequest(url: components.url!)
        let data = try await fetch(request)
        let html = String(decoding: data, as: UTF8.self)
        if Self.looksLikeChallenge(html) {
            throw SearchProviderError.decoding("DuckDuckGo served an anti-bot challenge")
        }
        guard let results = Self.parseDuckDuckGo(html: html), !results.isEmpty else {
            throw SearchProviderError.decoding("could not parse DuckDuckGo results")
        }
        return Array(results.prefix(maxResults))
    }

    /// The anomaly page carries the challenge script but zero result links.
    public static func looksLikeChallenge(_ html: String) -> Bool {
        !html.contains("result__a") && (html.contains("anomaly") || html.contains("challenge"))
    }

    // MARK: Bing RSS

    /// Bing's RSS output is the most stable scraping surface it offers:
    /// clean XML, real organic results with `mkt=en-US`, no JS.
    private func bingRSS(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "mkt", value: "en-US"),
            URLQueryItem(name: "count", value: String(maxResults))
        ]
        let request = Self.makeRequest(url: components.url!)
        let data = try await fetch(request)
        guard let items = Self.parseRSS(data: data), !items.isEmpty else {
            throw SearchProviderError.decoding("could not parse Bing results")
        }
        return Array(items.prefix(maxResults))
    }

    // MARK: Google News RSS

    /// Google's web results need JS, but its News RSS is a documented
    /// feed that works without any key.
    private func googleNewsRSS(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: "en-US"),
            URLQueryItem(name: "gl", value: "US"),
            URLQueryItem(name: "ceid", value: "US:en")
        ]
        let request = Self.makeRequest(url: components.url!)
        let data = try await fetch(request)
        guard let items = Self.parseRSS(data: data), !items.isEmpty else {
            throw SearchProviderError.decoding("could not parse Google News results")
        }
        return Array(items.prefix(maxResults))
    }

    // MARK: Parsers

    /// Extracts organic results from DuckDuckGo's html page. Anchors are
    /// scanned in two passes (opening tag, then inner text) so attribute
    /// order in the markup does not matter; titles and snippets are
    /// ordered lists zipped by position.
    public static func parseDuckDuckGo(html: String) -> [SearchResultItem]? {
        let anchorRegex = try? NSRegularExpression(
            pattern: #"<a\b([^>]*)>([\s\S]*?)</a>"#)
        let hrefRegex = try? NSRegularExpression(pattern: #"href="([^"]+)""#)
        let snippetRegex = try? NSRegularExpression(
            pattern: #"class="result__snippet"[^>]*>([\s\S]*?)</a>"#)
        guard let anchorRegex else { return nil }

        let ns = html as NSString
        let snippets = snippetRegex.map {
            $0.matches(in: html, range: NSRange(location: 0, length: ns.length))
        } ?? []

        var items: [SearchResultItem] = []
        for match in anchorRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let attrs = ns.substring(with: match.range(at: 1))
            guard attrs.contains("result__a") else { continue }
            let title = stripTags(ns.substring(with: match.range(at: 2)))
            guard let hrefRegex,
                  let hrefMatch = hrefRegex.firstMatch(
                    in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)),
                  hrefMatch.numberOfRanges >= 2
            else { continue }
            let href = (attrs as NSString).substring(with: hrefMatch.range(at: 1))
            guard let url = unwrapDDGRedirect(href) else { continue }
            let snippet = items.count < snippets.count && snippets[items.count].numberOfRanges >= 2
                ? stripTags(ns.substring(with: snippets[items.count].range(at: 1)))
                : ""
            items.append(SearchResultItem(title: title, url: url, snippet: snippet))
        }
        return items.isEmpty ? nil : items
    }

    /// DDG wraps result URLs in `//duckduckgo.com/l/?uddg=<encoded>`.
    public static func unwrapDDGRedirect(_ href: String) -> String? {
        guard let marker = href.range(of: "uddg=") else {
            return href.hasPrefix("http") ? href : nil
        }
        let rest = String(href[marker.upperBound...])
        let encoded = rest.prefix(while: { $0 != "&" })
        return encoded.removingPercentEncoding ?? String(encoded)
    }

    /// Shared RSS parser for Bing and Google News: `<item>` blocks with
    /// title, link and description children.
    public static func parseRSS(data: Data) -> [SearchResultItem]? {
        let xml = String(decoding: data, as: UTF8.self)
        guard let itemRegex = try? NSRegularExpression(pattern: #"<item>([\s\S]*?)</item>"#) else {
            return nil
        }
        let ns = xml as NSString
        let matches = itemRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length))

        var items: [SearchResultItem] = []
        for match in matches where match.numberOfRanges >= 2 {
            let block = ns.substring(with: match.range(at: 1))
            guard let title = tagValue("title", in: block),
                  let link = tagValue("link", in: block),
                  !link.isEmpty
            else { continue }
            let description = tagValue("description", in: block) ?? ""
            items.append(SearchResultItem(
                title: cleanRSSText(title),
                url: unescapeXML(link),
                snippet: cleanRSSText(description)
            ))
        }
        return items.isEmpty ? nil : items
    }

    private static func tagValue(_ tag: String, in block: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)>([\\s\\S]*?)</\(tag)>") else {
            return nil
        }
        let ns = block as NSString
        guard let match = regex.firstMatch(
            in: block, range: NSRange(location: 0, length: ns.length)),
            match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Removes simple HTML tags without regex: keep text outside `<...>` pairs.
    public static func stripTags(_ text: String) -> String {
        var result = ""
        var insideTag = false
        for char in text {
            if char == "<" {
                insideTag = true
            } else if char == ">" {
                insideTag = false
            } else if !insideTag {
                result.append(char)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// RSS descriptions are XML-escaped HTML (`&lt;a&gt;...&lt;/a&gt;&amp;nbsp;`).
    /// Unescape first so embedded markup becomes real tags, strip them,
    /// then unescape again for entities that were double-escaped.
    public static func cleanRSSText(_ raw: String) -> String {
        var text = stripTags(unescapeXML(raw))
        if text.contains("&") {
            text = unescapeXML(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}