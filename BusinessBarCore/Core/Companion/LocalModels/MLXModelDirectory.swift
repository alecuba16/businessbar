import Foundation

// MARK: - MLXModelDirectory

/// Live MLX catalog from Hugging Face. Like the repo check, every fetch is
/// user-initiated: nothing runs until the user presses Browse in the local
/// models sheet. The list endpoint carries no sizes, so sizes come from a
/// bounded batch of per-repo detail calls; entries with unknown sizes still
/// appear and sort last by downloads.
public enum MLXModelDirectory {
    public struct Item: Identifiable, Sendable, Equatable {
        public let id: String
        public let kind: MLXModelCatalog.Kind
        /// Total download size in bytes; nil until the detail call lands.
        public let sizeBytes: Int64?
        /// HF download count, for the popularity sort.
        public let downloads: Int

        public init(id: String, kind: MLXModelCatalog.Kind, sizeBytes: Int64?, downloads: Int) {
            self.id = id
            self.kind = kind
            self.sizeBytes = sizeBytes
            self.downloads = downloads
        }
    }

    public enum DirectoryError: Error, Sendable, LocalizedError {
        case requestFailed(String)

        public var errorDescription: String? {
            switch self {
            case .requestFailed(let detail):
                return "Browse failed: \(detail)"
            }
        }
    }

    /// Session for the directory calls. Injectable for tests.
    public static var session: URLSession = .shared

    /// Pipeline tags that can serve chat from mlx-lm or mlx-vlm. Whisper,
    /// TTS, embedding and image-generation repos are not chat models.
    public static let chatPipelineTags: Set<String> = ["text-generation", "image-text-to-text"]

    /// Cap on detail fetches per browse so one press stays bounded.
    public static let detailFetchLimit = 60

    /// Fetches the MLX chat catalog. One list call plus bounded per-repo
    /// size lookups, all running concurrently.
    public static func fetch() async throws -> [Item] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "author", value: "mlx-community"),
            URLQueryItem(name: "library_name", value: "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        guard let url = components.url else {
            throw DirectoryError.requestFailed("bad request URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DirectoryError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DirectoryError.requestFailed("HTTP \(code)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DirectoryError.requestFailed("unexpected payload")
        }

        let listed = json.compactMap { raw -> Item? in
            guard let id = raw["id"] as? String,
                  let tag = raw["pipeline_tag"] as? String,
                  chatPipelineTags.contains(tag)
            else { return nil }
            let downloads = raw["downloads"] as? Int ?? 0
            return Item(
                id: id,
                kind: tag == "image-text-to-text" ? .textAndImages : .text,
                sizeBytes: nil,
                downloads: downloads
            )
        }
        guard !listed.isEmpty else {
            throw DirectoryError.requestFailed("no chat models returned")
        }

        // Sizes need one detail call per repo; run them concurrently but
        // capped so a browse never turns into hundreds of requests.
        let targets = Array(listed.prefix(detailFetchLimit))
        let sizes = await withTaskGroup(of: (String, Int64?).self) { group in
            for item in targets {
                group.addTask {
                    await (item.id, repoSizeBytes(repoID: item.id))
                }
            }
            var result: [String: Int64] = [:]
            for await (id, size) in group {
                if let size { result[id] = size }
            }
            return result
        }
        return listed.map { item in
            Item(
                id: item.id,
                kind: item.kind,
                sizeBytes: sizes[item.id],
                downloads: item.downloads
            )
        }
    }

    /// Downloads (usedStorage) for one repo, nil when the call fails or
    /// the payload has no size. A zero means HF reported no storage, which
    /// reads as unknown here so a row never claims "0 bytes on disk".
    /// Failure is non-fatal: the item still lists, sorted by downloads
    /// instead of size.
    static func repoSizeBytes(repoID: String) async -> Int64? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // A zero means HF reported no storage, which reads as unknown here
        // so a row never claims "0 bytes on disk".
        let size = Int64(json["usedStorage"] as? Double ?? 0)
        return size > 0 ? size : nil
    }
}