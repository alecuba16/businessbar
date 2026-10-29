import Foundation

/// One model row as reported by an OpenAI-compatible /models endpoint.
/// Effort values ride along only when the endpoint publishes them
/// (OpenRouter's supported_parameters carries reasoning_effort); most
/// servers send no capability metadata at all.
public struct RemoteModelInfo: Identifiable, Equatable, Sendable {
    public let id: String
    /// Accepted reasoning-effort values for this model, nil when the
    /// endpoint does not publish them.
    public let effortOptions: [String]?
    public let supportsReasoning: Bool

    public init(id: String, effortOptions: [String]? = nil, supportsReasoning: Bool = false) {
        self.id = id
        self.effortOptions = effortOptions
        self.supportsReasoning = supportsReasoning
    }
}

public enum RemoteModelCatalog {
    /// Parses the JSON body of GET {baseURL}/models. Returns nil when the
    /// payload is not the expected {data: [...]} shape, nil entries are
    /// dropped, and a missing id drops the row.
    public static func parse(data: Data) -> [RemoteModelInfo]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["data"] as? [[String: Any]] else {
            return nil
        }
        let levels = EffortVocabulary.defaultLevels
        return raw.compactMap { entry -> RemoteModelInfo? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let params = entry["supported_parameters"] as? [String] ?? []
            let supportsReasoning = params.contains("reasoning")
                || params.contains("reasoning_effort")
                || (entry["reasoning"] as? Bool == true)
            let options = params.contains("reasoning_effort")
                ? levels.filter { $0 != "none" } : nil
            return RemoteModelInfo(
                id: id,
                effortOptions: options,
                supportsReasoning: supportsReasoning
            )
        }
    }

    /// Fetches the model list from an OpenAI-compatible endpoint, GET
    /// {baseURL}/models with the given key and headers. The response
    /// carries no capability metadata on most servers, so reasoning hints
    /// ride along only when the endpoint publishes them.
    public static func fetch(
        baseURL: String,
        apiKey: String,
        headers: [(name: String, value: String)] = [],
        session: URLSession = .shared
    ) async throws -> [RemoteModelInfo] {
        var normalized = baseURL
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard let url = URL(string: normalized + "/models") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return parse(data: data) ?? []
    }
}