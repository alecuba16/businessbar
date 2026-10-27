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
/// Decodes tolerantly: top-level `results` or `data`, item keys
/// url/link and content/snippet/description.
public final class CustomSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Custom"

    private let endpoint: URL
    private let headerName: String?
    private let headerValue: String?
    private let session: URLSession

    public init(
        endpoint: URL,
        headerName: String? = nil,
        headerValue: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.headerName = headerName
        self.headerValue = headerValue
        self.session = session
    }

    public func search(query: String, maxResults: Int) async throws -> [SearchResultItem] {
        let body: [String: Any] = [
            "query": query,
            "max_results": SearchProviderSupport.clampedResultCount(maxResults)
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw SearchProviderError.decoding("could not encode request body")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let headerName, let headerValue, !headerName.isEmpty {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }
        request.httpBody = payload
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

    static func decodeItems(from data: Data, response: URLResponse) throws -> [SearchResultItem] {
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