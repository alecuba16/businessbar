import Foundation

/// One persisted conversation. Stored as a single JSON file so a corrupt
/// session never takes down the others, and loading stays cheap when the
/// list only needs the summary fields.
public struct ChatSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Snapshot of a stored session for list rendering: the fields the
/// history rows show, kept apart from the full session type so the UI
/// depends on the summary shape only.
public struct ChatSessionSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int

    public init(id: UUID, title: String, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}

/// Loads, saves and deletes chat sessions on disk. One JSON file per
/// session under Application Support, so history survives restarts and
/// one corrupted file cannot wipe the rest.
public final class ChatSessionStore: @unchecked Sendable {
    public static let shared = ChatSessionStore()

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ioQueue = DispatchQueue(label: "com.businessbar.chatsessions", qos: .utility)

    /// Store rooted at the real Application Support directory (the shared
    /// instance and any default construction keep this location).
    private convenience init() {
        self.init(directoryURL: ChatSessionStore.defaultDirectoryURL())
    }

    /// Store rooted at an explicit directory (test and harness isolation).
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static func defaultDirectoryURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("BusinessBar", isDirectory: true)
            .appendingPathComponent("ChatSessions", isDirectory: true)
    }

    /// ISO8601 keeps the files readable but drops sub-second precision,
    /// so saved dates are truncated to whole seconds before encoding. This
    /// keeps a decoded session equal to the one in memory.
    private func truncatingDates(_ session: ChatSession) -> ChatSession {
        var truncated = session
        truncated.createdAt = Date(timeIntervalSince1970: floor(session.createdAt.timeIntervalSince1970))
        truncated.updatedAt = Date(timeIntervalSince1970: floor(session.updatedAt.timeIntervalSince1970))
        return truncated
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// All stored sessions, newest activity first. Corrupt files are
    /// skipped rather than failing the whole listing.
    public func loadAll() -> [ChatSession] {
        ioQueue.sync {
            let files = (try? FileManager.default
                .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey]))
                ?? []
            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(ChatSession.self, from: data)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Writes the session atomically: a half-written file never replaces
    /// the previous good copy.
    public func save(_ session: ChatSession) {
        ioQueue.sync {
            let prepared = truncatingDates(session)
            guard let data = try? encoder.encode(prepared) else { return }
            try? data.write(to: fileURL(for: prepared.id), options: .atomic)
        }
    }

    public func delete(id: UUID) {
        ioQueue.sync {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
    }

    public func load(id: UUID) -> ChatSession? {
        ioQueue.sync {
            guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
            return try? decoder.decode(ChatSession.self, from: data)
        }
    }

    // MARK: - Cleanup

    /// Deletes every stored session.
    public func deleteAll() {
        ioQueue.sync {
            let files = (try? FileManager.default
                .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))
                ?? []
            for url in files where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Deletes sessions not updated within the given number of days.
    /// Returns the number of removed sessions.
    @discardableResult
    public func deleteOlderThan(days: Int) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return prune(olderThan: cutoff)
    }

    /// Keeps only the newest `count` sessions, deleting the rest.
    /// Returns the number of removed sessions.
    @discardableResult
    public func keepNewestSessions(_ count: Int) -> Int {
        guard count >= 0 else { return 0 }
        let sessions = loadAll()
        guard sessions.count > count else { return 0 }
        let doomed = sessions.suffix(sessions.count - count)
        for session in doomed {
            delete(id: session.id)
        }
        return doomed.count
    }

    /// Applies the configured retention policy. Zero disables that rule;
    /// both rules can combine (age AND count limits prune independently).
    /// Returns the number of removed sessions.
    @discardableResult
    public func applyRetention(maxAgeDays: Int, maxSessionCount: Int) -> Int {
        var removed = 0
        if maxAgeDays > 0 {
            removed += deleteOlderThan(days: maxAgeDays)
        }
        if maxSessionCount > 0 {
            removed += keepNewestSessions(maxSessionCount)
        }
        return removed
    }

    private func prune(olderThan cutoff: Date) -> Int {
        ioQueue.sync {
            let files = (try? FileManager.default
                .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))
                ?? []
            var removed = 0
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let session = try? decoder.decode(ChatSession.self, from: data)
                else { continue }
                if session.updatedAt < cutoff {
                    try? FileManager.default.removeItem(at: url)
                    removed += 1
                }
            }
            return removed
        }
    }
}