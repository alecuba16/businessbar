import Foundation

// MARK: - SearchResultItem

/// One web result returned by a search provider.
public struct SearchResultItem: Codable, Sendable, Equatable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

// MARK: - SearchProviderError

/// Unified error surface for all search providers.
public enum SearchProviderError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case http(Int)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Search is not configured. Add an API key in Settings."
        case .http(let code):
            return "Search provider returned HTTP \(code)."
        case .decoding(let detail):
            return "Could not read search results: \(detail)"
        case .transport(let detail):
            return "Search request failed: \(detail)"
        }
    }
}

// MARK: - SearchProvider

/// Backend-agnostic interface for running a web search.
public protocol SearchProvider: Sendable {
    /// Human-presentable name for logs and settings UI.
    var name: String { get }

    /// Runs `query` and returns at most `maxResults` items.
    func search(query: String, maxResults: Int) async throws -> [SearchResultItem]
}

// MARK: - Shared request helpers

enum SearchProviderSupport {
    /// Providers cap results server-side; anything outside 1...10 is not useful.
    static func clampedResultCount(_ maxResults: Int) -> Int {
        min(max(1, maxResults), 10)
    }

    static func decodedItems(
        from data: Data,
        response: URLResponse,
        snippetKeys: [String] = ["snippet"]
    ) throws -> [SearchResultItem] {
        guard let http = response as? HTTPURLResponse else {
            throw SearchProviderError.decoding("unexpected non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SearchProviderError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchProviderError.decoding("response is not a JSON object")
        }
        guard let raw = json["results"] as? [[String: Any]] else {
            throw SearchProviderError.decoding("missing results array")
        }
        return raw.compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String
            else { return nil }
            let snippet = snippetKeys.lazy
                .compactMap { item[$0] as? String }
                .first ?? ""
            return SearchResultItem(title: title, url: url, snippet: snippet)
        }
    }

    static func transportError(_ error: Error) -> SearchProviderError {
        SearchProviderError.transport(error.localizedDescription)
    }
}

// MARK: - BraveSearchProvider

/// Client for the Brave Search web search endpoint (`res/v1/web/search`).
/// The llm/context endpoint was rejected: it bills per query differently
/// and is not available on all plans.
public final class BraveSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Brave Search"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func search(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        guard !apiKey.isEmpty else { throw SearchProviderError.notConfigured }

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(SearchProviderSupport.clampedResultCount(maxResults)))
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            let items = try SearchProviderSupport.decodedItems(
                from: data, response: response, snippetKeys: ["description"])
            // The API returns <b> highlight tags in descriptions.
            return items.map {
                SearchResultItem(title: $0.title, url: $0.url, snippet: Self.stripTags($0.snippet))
            }
        } catch let error as SearchProviderError {
            throw error
        } catch {
            throw SearchProviderSupport.transportError(error)
        }
    }

    /// Removes simple HTML tags without regex: keep text outside `<...>` pairs.
    static func stripTags(_ text: String) -> String {
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
        return result
    }
}

// MARK: - TavilySearchProvider

/// Client for the Tavily search API. The api_key travels in the POST body
/// because that is their documented stable form.
public final class TavilySearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Tavily"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func search(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        guard !apiKey.isEmpty else { throw SearchProviderError.notConfigured }

        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": SearchProviderSupport.clampedResultCount(maxResults),
            "include_answer": false
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw SearchProviderError.decoding("could not encode request body")
        }

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            let items = try SearchProviderSupport.decodedItems(
                from: data, response: response, snippetKeys: ["content"])
            return items.map {
                SearchResultItem(title: $0.title, url: $0.url, snippet: $0.snippet)
            }
        } catch let error as SearchProviderError {
            throw error
        } catch {
            throw SearchProviderSupport.transportError(error)
        }
    }
}

// MARK: - CustomSearchProvider

/// Escape hatch for arbitrary user-supplied search endpoints.
///
/// Two modes share one decoder. URL-template mode: the endpoint contains
/// a `{query}` placeholder (and optionally `{count}`), the query goes into
/// the URL percent-encoded, and custom headers ride along. Legacy POST
/// mode: no placeholder means the old body form, kept so existing setups
/// keep working.
public final class CustomSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Custom"

    private let endpoint: URL
    private let headers: [(name: String, value: String)]
    private let session: URLSession

    public init(
        endpoint: URL,
        headers: [(name: String, value: String)] = [],
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.session = session
    }

    /// Old single-header initializer kept for callers that have not
    /// migrated to the header list form.
    public convenience init(
        endpoint: URL,
        headerName: String?,
        headerValue: String?,
        session: URLSession = .shared
    ) {
        let header: [(name: String, value: String)]
        if let headerName, !headerName.isEmpty, let headerValue {
            header = [(name: headerName, value: headerValue)]
        } else {
            header = []
        }
        self.init(endpoint: endpoint, headers: header, session: session)
    }

    /// True when the endpoint contains the URL-template placeholder and
    /// template mode applies. `URL(string:)` percent-encodes curly braces, so
    /// both the raw and the encoded form must be accepted as template input.
    public static func isTemplateURL(_ endpoint: URL) -> Bool {
        endpoint.absoluteString.contains("{query}")
            || endpoint.absoluteString.contains("%7Bquery%7D")
    }

    /// Substitutes `{query}` and `{count}` in a template URL. The query is
    /// percent-encoded so qualifiers and symbols survive. Handles the raw
    /// brace form and the percent-encoded form left behind by `URL(string:)`.
    public static func expandedTemplateURL(
        _ template: URL,
        query: String,
        count: Int
    ) -> URL? {
        var raw = template.absoluteString
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        raw = raw.replacingOccurrences(of: "{query}", with: encodedQuery)
        raw = raw.replacingOccurrences(of: "%7Bquery%7D", with: encodedQuery)
        raw = raw.replacingOccurrences(of: "{count}", with: String(count))
        raw = raw.replacingOccurrences(of: "%7Bcount%7D", with: String(count))
        return URL(string: raw)
    }

    public func search(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        let count = SearchProviderSupport.clampedResultCount(maxResults)

        var request: URLRequest
        if Self.isTemplateURL(endpoint),
           let expanded = Self.expandedTemplateURL(endpoint, query: query, count: count) {
            request = URLRequest(url: expanded)
        } else {
            let body: [String: Any] = [
                "query": query,
                "max_results": count
            ]
            guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
                throw SearchProviderError.decoding("could not encode request body")
            }
            request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
        }
        for header in headers where !header.name.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            return try Self.decodeItems(from: data, response: response)
        } catch let error as SearchProviderError {
            throw error
        } catch {
            throw SearchProviderSupport.transportError(error)
        }
    }

    public static func decodeItems(from data: Data, response: URLResponse) throws -> [SearchResultItem] {
        guard let http = response as? HTTPURLResponse else {
            throw SearchProviderError.decoding("unexpected non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SearchProviderError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchProviderError.decoding("response is not a JSON object")
        }
        guard let raw = (json["results"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) else {
            throw SearchProviderError.decoding("missing results or data array")
        }
        return raw.compactMap { item in
            guard let title = item["title"] as? String,
                  let url = (item["url"] as? String) ?? (item["link"] as? String)
            else { return nil }
            let snippet = (item["content"] as? String)
                ?? (item["snippet"] as? String)
                ?? (item["description"] as? String)
                ?? ""
            return SearchResultItem(title: title, url: url, snippet: snippet)
        }
    }
}

// MARK: - GitHubSearchProvider

/// Client for the GitHub code search endpoint. Requires a token: the
/// endpoint is authenticated-only and caps at 10 requests per minute.
public final class GitHubSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "GitHub Code Search"

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    public func search(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        guard !token.isEmpty else { throw SearchProviderError.notConfigured }

        var components = URLComponents(string: "https://api.github.com/search/code")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: String(SearchProviderSupport.clampedResultCount(maxResults)))
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The text-match media type asks for fragments with the matching
        // terms, which is the only snippet source the endpoint offers.
        request.setValue("application/vnd.github.text-match+json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            return try Self.decodeItems(from: data, response: response)
        } catch let error as SearchProviderError {
            throw error
        } catch {
            throw SearchProviderSupport.transportError(error)
        }
    }

    public static func decodeItems(from data: Data, response: URLResponse) throws -> [SearchResultItem] {
        guard let http = response as? HTTPURLResponse else {
            throw SearchProviderError.decoding("unexpected non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403 {
                throw SearchProviderError.http(403)
            }
            throw SearchProviderError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["items"] as? [[String: Any]]
        else {
            throw SearchProviderError.decoding("missing items array")
        }
        return raw.compactMap { item in
            guard let repo = item["repository"] as? [String: Any],
                  let repoName = repo["full_name"] as? String,
                  let htmlURL = item["html_url"] as? String
            else { return nil }
            let path = item["path"] as? String ?? ""
            // First text-match fragment is the matching code, the best
            // snippet the endpoint provides.
            let fragment = (item["text_matches"] as? [[String: Any]])?
                .first?["fragment"] as? String ?? ""
            return SearchResultItem(
                title: "\(repoName)/\(path)",
                url: htmlURL,
                snippet: fragment
            )
        }
    }
}

// MARK: - SearchToolCatalog

/// OpenAI tool schema and output shaping for the web_search tool.
public enum SearchToolCatalog {
    /// OpenAI-format schema for the `web_search` tool offered to the model.
    public static func webSearchToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current information. Use for questions about recent events, facts you are unsure about, or anything after your training cutoff.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "The search query to run on the web."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    /// OpenAI-format schema for the `github_search` code search tool.
    /// Qualifiers are documented in the description because the model has
    /// no other way to learn the endpoint's query syntax.
    public static func githubSearchToolSchema() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "github_search",
                "description": "Search for code on GitHub. Supports qualifiers like repo:owner/name, org:name, user:name, language:python, path:src, and filename:. Requires at least one search term. Best for finding real code, definitions, or usage examples in public and accessible private repositories.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "GitHub code search query with optional qualifiers, for example 'parseJSON language:swift repo:apple/swift'"
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    /// Encodes results into a clean `{results: [...]}` JSON wrapper for the model.
    public static func toolOutput(from results: [SearchResultItem]) -> String {
        struct Wrapper: Codable {
            let results: [SearchResultItem]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Wrapper(results: results)) else {
            return "{\"results\":[]}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}